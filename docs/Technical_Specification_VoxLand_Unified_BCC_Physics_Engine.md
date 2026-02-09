# **Technical Specification: VoxLand Unified BCC Physics Engine**

**Version:** 1.0 (Final Draft)

**Target Architecture:** GPU Compute (Vulkan/Godot RD)

**Grid Topology:** Body-Centered Cubic (BCC) / Truncated Octahedron (TO)

## **1\. Core Architecture Overview**

The system utilizes a **Hybrid Lagrangian-Eulerian** approach.

1. **Data:** Voxels are treated as Lagrangian material points carrying mass, momentum, and deformation gradients.  
2. **Solver:** **MLS-MPM** handles the continuum mechanics (collisions, friction, momentum conservation) on a sparse BCC background grid.  
3. **Rigidity & Fracture:** A **Graph-Based Overlay** tracks structural integrity. Rigid bodies are not separate physics objects but "Islands" of particles constrained to move together until stress breaks their bond bitmasks.

## **2\. Data Structures**

### **2.1 The Particle State (Lagrangian)**

Stored in large StorageBuffers. Access is linear \[0..N\].

OpenGL Shading Language

struct Particle {  
    vec3  position;       // World space position (floating point)  
    vec3  velocity;       // Velocity vector  
    mat3  affine\_C;       // Affine velocity field (APIC) for angular momentum  
    mat3  def\_grad\_F;     // Deformation Gradient (elasticity/plasticity)  
    float mass;           // Static mass  
    float volume;         // Initial volume  
    uint  material\_id;    // 0=Empty, 1=Sand, 2=Stone, 8=Glass  
      
    // HYBRID EXTENSIONS  
    uint  bond\_mask;      // 14 bits representing connection to BCC neighbors  
    uint  island\_id;      // ID of the Rigid Island this particle belongs to  
    uint  flags;          // Bit 0: Sleeping, Bit 1: Static (Bedrock)  
};

### **2.2 The Background Grid (Eulerian)**

A sparse hash map or block-based sparse grid (aligned with Godot's Brickmap).

**Topology:** BCC. Valid nodes are integer coordinates $(x, y, z)$ where x%2 \== y%2 \== z%2.

OpenGL Shading Language

struct GridNode {  
    int   mass\_fixed;     // Fixed-point atomic accumulator (mass \* 10000\)  
    ivec3 mom\_fixed;      // Fixed-point atomic accumulator (momentum \* 10000\)  
    vec3  velocity\_new;   // Calculated velocity after solve  
    uint  active\_flags;   // Used for sparse activation  
};

## ---

**3\. The Physics Pipeline (Per Frame)**

The simulation loop is a sequence of Compute Shader dispatches. Barriers must be placed between stages.

### **Stage 1: Kinematic Island Update (The "Rigid" Phase)**

*Goal: Optimization and Rigid Motion enforcement.*

1. **Check Sleep:** For every Island ID, check total momentum from previous frame. If \< Threshold, set flags |= SLEEPING.  
2. **Rigid Integration:** For active Islands, compute the Center of Mass (CoM) and aggregate Rigid Body transformation matrix.  
3. **Particle Update:** If a particle is part of a Rigid Island, override its velocity/position based on the Island's rigid motion *before* the MPM step. This prevents the "melting" artifact common in MPM.

### **Stage 2: Particle-to-Grid (P2G) Transfer**

*Goal: Scatter mass and momentum to the grid.*

* **Kernel:** p2g\_scatter.glsl  
* **Logic:**  
  1. Iterate active particles.  
  2. Compute **BCC Box Spline** weights for the 14 nearest grid nodes.  
  3. **Atomic Add:** Add mass and momentum (mass \* velocity \+ affine\_contribution) to grid nodes.  
  * *Godot Implementation Note:* GLSL atomicAdd only supports int/uint. You **must** use fixed-point arithmetic:  
    OpenGL Shading Language  
    atomicAdd(grid.mass\_fixed, int(particle\_mass \* weight \* 10000.0));

### **Stage 3: Grid Solve & Boundary Conditions**

*Goal: Apply gravity, collision, and friction.*

* **Kernel:** grid\_update.glsl  
* **Logic:**  
  1. Convert fixed-point Mass/Momentum back to float: v \= mom / mass.  
  2. Apply Gravity: v \+= g \* dt.  
  3. **Floor/Wall Collision:** Raymarch the static signed distance field (SDF) of the level. If dist \< 0, project velocity to tangent (friction) or zero (sticky).

### **Stage 4: Grid-to-Particle (G2P) Transfer & Constitutive Update**

*Goal: Update particle velocity and calculate stress.*

* **Kernel:** g2p\_gather.glsl  
* **Logic:**  
  1. Gather weighted velocity from 14 grid neighbors.  
  2. Update Particle Velocity (v\_pic) and Affine Matrix (C).  
  3. **Constitutive Law (Stress Calculation):**  
     * Update Deformation Gradient $\\mathbf{F}$.  
     * **Sand:** Apply Drucker-Prager yield condition (project $\\mathbf{F}$ to cone surface).  
     * **Stone:** Apply linear elasticity. Compute Cauchy Stress $\\boldsymbol{\\sigma}$.

### **Stage 5: Fracture & Topology (The "Hybrid" Logic)**

*Goal: Break bonds and detect splits.*

* **Kernel:** fracture\_update.glsl  
* **Logic:**  
  1. **Stress Projection:** Project the particle's stress tensor $\\boldsymbol{\\sigma}$ onto the 14 BCC face normals.  
  2. **Bond Breaking:** If normal stress on face $i$ \> tensile\_strength:  
     * particle.bond\_mask &= \~(1 \<\< i); (Sever bond).  
  3. **Graph Analysis (CCL):** Run **Playne-Equivalence Algorithm** (GPU Connected Component Labeling).  
     * Graph Nodes \= Particles.  
     * Edges \= Existing bond\_mask bits.  
     * If a single island\_id splits into two distinct labels, spawn a new Rigid Island ID for the child.

### **Stage 6: Advection**

* **Kernel:** advect.glsl  
* Update position: x \+= v \* dt.  
* Clamp to world bounds.

## ---

**4\. Implementation Details for Godot**

### **4.1 Fixed-Point Atomics**

To circumvent the lack of GL\_EXT\_shader\_atomic\_float on some drivers:

* **Precision:** 1 unit \= 1/10000.0.  
* **Range:** 32-bit int max is \~2 billion. $2 \\times 10^9 / 10000 \= 200,000$ mass units per cell. This is sufficient for sand/stone density.  
* **Overflow Protection:** Clamp maximum mass in shader to prevent wrap-around artifacts.

### **4.2 The "Bitmask Bond"**

The 14 neighbors of a truncated octahedron in BCC are:

* **8 Hexagonal Faces:** vectors $(\\pm 1, \\pm 1, \\pm 1)$  
* **6 Square Faces:** vectors $(\\pm 2, 0, 0), (0, \\pm 2, 0), (0, 0, \\pm 2)$  
* **Data Layout:** uint16. Bits 0-7 \= Hex neighbors. Bits 8-13 \= Square neighbors.  
* **Anisotropy:** This allows a stone pillar to crack *horizontally* (cleavage) while remaining solid vertically.

### **4.3 Rendering Integration**

Standard voxel rendering snaps to the grid. To visualize the physics fidelity:

1. **Simulation:** Particles move continuously (float positions).  
2. **Rendering:**  
   * Do **not** snap SDF directly to the integer grid.  
   * Instead, compute the **SDF of the Truncated Octahedron** centered at the particle's *floating point* position.  
   * Union these SDFs in the raymarcher.  
   * *Optimization:* Only update the Grid-based SDF structure (Brickmap) when a particle moves more than 0.5 units from its previous cell center.

### **4.4 Dispatch Safety (Bounds)**

Several kernels dispatch in fixed workgroup sizes (e.g. `local_size_x = 256`) and may not include explicit bounds checks. In those cases, you must ensure one of:

* **Pad SSBO allocations** to the dispatch-rounded element count (recommended when the extra elements are small and always "empty").  
* **Add explicit bounds checks** by passing the relevant element count into the shader.

**Why this matters:** an out-of-bounds access in any compute stage can corrupt unrelated GPU buffers and present as "physics instability" (extreme velocities, apparent mass loss, COM drifting against gravity, etc.).

Concrete example in this codebase: the rigid-island finalize stage (`mpm_island_finalize.glsl`) uses `local_size_x = 256` and relies on the island buffers being sized to `ceil(island_count / 256) * 256` elements.

## **5\. Acceptance Test Cases**

### **Test A: The Hourglass (Granular Flow)**

* **Setup:** 50k Sand particles in upper bulb.  
* **Pass Criteria:** Sand flows at a constant rate. Pile forms a stable angle of repose (approx 30 degrees) in the lower bulb. Energy does not explode (sand stops moving when settled).

### **Test B: The Stone Pillar (Rigid \+ Fracture)**

* **Setup:** A 10x2x2 pillar of Stone voxels, supported only at one end (cantilever).  
* **Pass Criteria:**  
  1. The pillar sags slightly (elasticity) but holds together.  
  2. A heavy weight is dropped on the tip.  
  3. The pillar snaps clean off near the support.  
  4. The broken piece falls as a solid unit (angular momentum conserved).  
  5. Upon hitting the ground, the falling piece may shatter further into debris.

### **Test C: The "Jelly" Test (Stability)**

* **Setup:** A solid block of Stone.  
* **Pass Criteria:** The block must **not** slowly deform, melt, or drift over time (a common MPM artifact). The "Kinematic Island" system must keep it perfectly rigid until stress limits are exceeded.

## **6\. Mathematical Appendix (BCC Basis)**

For a particle at $\\mathbf{x}\_p$ and grid node $\\mathbf{x}\_i$, the weight $N(\\mathbf{x}\_p \- \\mathbf{x}\_i)$ uses the linear BCC basis:

$$N(\\mathbf{r}) \= \\begin{cases} 1 \- \\frac{|\\mathbf{r}|}{h} & \\text{if } |\\mathbf{r}| \< h \\text{ (approx)} \\\\ 0 & \\text{otherwise} \\end{cases}$$  
*Note:* For exact conservation on BCC, use the **Linear Box Spline** which is the convolution of vectors along the four body diagonals.

**Simplified Fast Kernel:**

Barycentric coordinates on the Delaunay tetrahedron of the BCC lattice.

1. Identify which tetrahedron $\\mathbf{x}\_p$ falls into (based on signs of $x,y,z$ relative to cell center).  
2. Compute linear interpolation weights $w\_1, w\_2, w\_3, w\_4$ for the 4 vertices of that tetrahedron.  
3. All other 10 neighbors get weight 0\.

This is faster than B-Splines and sufficient for gaming physics.
