# **The Granular Frontier: Architectural Paradigms and Implementation Strategies for GPU-Accelerated Voxel Physics Engines**

## **1\. Introduction: The Transition to Granular Volumetrics**

The domain of real-time computer graphics and physics simulation is currently undergoing a fundamental paradigm shift, moving from the approximation of surfaces to the simulation of volumes. For over three decades, the industry standard has relied on Boundary Representation (B-Rep), where objects are defined by their hollow outer shells—polygonal meshes. In this traditional model, physics is an abstraction; interactions are calculated using simplified collision hulls (capsules, boxes, and convex hulls) that approximate the geometry but ignore the internal constitution of the object. While computationally efficient, this approach inherently limits the potential for emergent interactivity. A mesh-based wall is a static plane that can perhaps play a destruction animation, but it cannot structurally fail based on stress, crumble into constituent bricks, or allow fluids to permeate its cracks based on material porosity.

The emergence of **Granular Voxel Physics Engines** represents the antithesis of this approximation. In a fully granular volumetric engine, objects are defined not by their boundaries, but by their content. A wall is no longer a texture mapped onto two triangles; it is a collection of thousands or millions of discrete volumetric pixels (voxels), each possessing independent material properties, state data, and physical agency. This shift allows for a level of interactivity previously reserved for offline CGI simulations: terrain that erodes under fluid pressure, wood that burns and propagates fire based on density and oxygen access, and structures that collapse dynamically when their load-bearing supports are severed.

However, the computational cost of this fidelity is staggering. Simulating a standard high-definition game world at a granular level involves tracking the state of billions of individual elements. Central Processing Units (CPUs), even with modern multi-core architectures, are fundamentally ill-equipped for this task due to their focus on serial processing and complex branch prediction. The only viable hardware platform for such massive parallelism is the Graphics Processing Unit (GPU). Projects such as John Lin’s sandbox, *Teardown* by Tuxedo Labs, and the *Octo* engine have pioneered the use of General-Purpose Computing on Graphics Processing Units (GPGPU) to offload the entire simulation loop—physics, logic, and rendering—onto the graphics card.

This report provides an exhaustive technical analysis of the implementation details required to engineer such systems. It dissects the specific compute shader architectures, memory management strategies for handling massive sparse datasets, and the integration of software-based raytracing that allows these engines to render dynamic, mutable worlds in real-time. By examining the current state of the art, including the rejection of traditional structures like Sparse Voxel Octrees (SVOs) in favor of more dynamic alternatives like Brickmaps and Hash Grids, this document outlines the engineering path to achieving the "Holy Grail" of physics simulation: a world where every pixel is a physical particle.

## ---

### Project-Specific Note: Lattice-Based Voxels (Truncated Octahedra)

This project uses a truncated-octahedron lattice for voxel placement and adjacency. Any cubic "grid" sizes discussed below (e.g., indirection grids or brick dimensions) refer to GPU storage/tiling and do not imply cubic spatial voxels. The lattice mapping from cell coordinates to world space is a separate layer and is the authoritative source of spatial alignment and neighbor relationships.

**2\. Computational Architecture: The GPU Simulation Pipeline**

The foundational requirement of a granular physics engine is the ability to update millions of active elements (voxels) sixty times per second. This necessitates a move away from object-oriented programming paradigms typically found in engines like Unity or Unreal, towards data-oriented design (DOD) implemented via Compute Shaders.

### **2.1 The Compute Shader Paradigm**

In a traditional game loop, the CPU calculates the new positions of objects and sends draw calls to the GPU. In a granular voxel engine, this bandwidth (the PCIe bus) is too narrow to transfer the state of millions of voxels per frame.1 Therefore, the simulation data must remain resident in Video Random Access Memory (VRAM).3

The simulation is executed by **Compute Shaders**—programs running on the GPU that are not bound to the graphics pipeline’s vertex/fragment structure. These shaders operate on 1D, 2D, or 3D grids of threads. For a voxel engine, the thread group architecture typically mirrors the spatial decomposition of the world. A common configuration involves dispatching thread groups of dimension $$ (512 threads), which maps efficiently to the wavefront (AMD) or warp (NVIDIA) size of the underlying hardware, maximizing occupancy and hiding memory latency.

### **2.2 3D Cellular Automata and State Management**

The physics logic in engines like John Lin’s sandbox is rooted in 3D Cellular Automata (CA). Unlike rigid body physics, which solves constraints for a connected system, CA applies local rules to each cell based on its neighbors.5 The state of a voxel at position $P(x,y,z)$ at time $t+1$ is a function of the neighborhood of $P$ at time $t$.

#### **2.2.1 The Double-Buffering Necessity**

A critical implementation detail is the management of simulation state to prevent race conditions. If a single buffer is used for both reading and writing, the simulation becomes non-deterministic and order-dependent. For instance, if the thread for voxel $A$ runs before voxel $B$, and $A$ moves into $B$'s position, voxel $B$'s thread might read corrupt data.

To solve this, state-of-the-art implementations utilize **Double Buffering** (also known as Ping-Pong buffering).7 Two identical 3D textures or StructuredBuffers are allocated in VRAM: StateBuffer\_Read and StateBuffer\_Write. During the simulation dispatch, all threads read exclusively from StateBuffer\_Read and write their results to StateBuffer\_Write. At the end of the frame, the pointers to these buffers are swapped. This ensures that every voxel makes its decision based on a consistent snapshot of the previous frame.9

#### **2.2.2 The Challenge of Conservation of Mass**

Standard CA rules can easily violate conservation of mass in a parallel environment. If two sand voxels at $(10, 10, 10)$ and $(12, 10, 10)$ both attempt to move into the same empty space at $(11, 9, 10)$, a collision occurs. In a naive implementation, both might write their ID to the target voxel, resulting in one overwriting the other and a loss of mass. Conversely, if both detect the space as empty and move, they might merge into a single voxel (mass loss) or duplicate (mass gain).

High-fidelity engines address this via **Atomic Operations** or **Stochastic Locking**. The High Level Shading Language (HLSL) provides intrinsics like InterlockedCompareExchange. A thread attempting to move a particle into a target cell will perform an atomic operation to "claim" the cell. If the claim succeeds, the move is finalized; if it fails (because another thread claimed it nanoseconds earlier), the particle remains in place or attempts an alternative move vector.10 While effective, atomics introduce serialization at the memory controller level, which can degrade performance in highly dense scenes (e.g., a collapsing pile of sand where extreme contention for empty space exists).

### **2.3 Optimization Strategies: Active Voxel Lists**

A naive approach dispatches a thread for every voxel in the world grid. For a world of size $1024^3$ (a relatively small sandbox), this equates to over 1 billion threads. Even on an NVIDIA RTX 4090, dispatching a billion threads where 99% of them simply return (because the voxel is empty or static) is prohibitively expensive due to the overhead of thread scheduling and memory bandwidth consumption.11

The solution adopted by performant engines is the **Indirect Dispatch** mechanism coupled with an **Active Voxel List**.12

1. **AppendBuffer Architecture:** The engine maintains a list of "active" chunks—regions of space containing dynamic materials (falling sand, flowing water, fire). Static terrain does not require simulation updates.  
2. **Simulation Step:** When a voxel moves from an active chunk into a static chunk, the static chunk is flagged as active and added to the AppendBuffer.  
3. **Indirect Execution:** The CPU does not know how many chunks are active. Instead, the AppendBuffer's hidden counter is used as the argument for DispatchComputeIndirect. This allows the GPU to determine its own workload dynamically without CPU intervention or PCIe latency.13

By decoupling the simulation cost from the total world volume, engines can support theoretically infinite static worlds, provided the volume of *moving* matter remains within the GPU's compute budget.

## ---

**3\. Memory Management: The Data Structure Dilemma**

The choice of data structure is the single most defining characteristic of a voxel engine. It dictates the memory footprint, the speed of physics queries, and the rendering technique. The research indicates a strong bifurcation in the industry: structures optimized for static compression (rendering) versus structures optimized for dynamic updates (physics).

### **3.1 The Failure of Sparse Voxel Octrees (SVO) for Dynamics**

Sparse Voxel Octrees (SVOs) have long been considered the standard for voxel representation. They offer $O(\\log N)$ access times and efficient empty-space skipping. However, the consensus among developers of *granular* physics engines (John Lin, Tuxedo Labs) is that **SVOs are unsuitable for dynamic physics**.4

The primary bottleneck is the update cost. In an octree, modifying a single leaf node (e.g., a grain of sand moving) requires traversing the tree from the root and potentially rebalancing or reallocating nodes if the sparsity structure changes (e.g., a voxel moving into previously empty void space). This "bubbling up" of state changes makes parallel updates extremely difficult to synchronize, as multiple threads might attempt to modify the same parent pointer simultaneously. Furthermore, the pointer indirection required to traverse an SVO is cache-unfriendly on GPUs, where memory latency is the primary performance killer.15

### **3.2 Sparse Voxel DAGs (SVDAG): The Compression King**

For static geometry, the **Sparse Voxel Directed Acyclic Graph (SVDAG)** is the state-of-the-art solution.16 Unlike an octree, which is a tree structure, a DAG allows different parent nodes to point to the same child node. If two sub-volumes of the world are identical (e.g., two identical stone pillars), they share the same memory address.

#### **3.2.1 Implementation Mechanics**

The construction of an SVDAG is typically a bottom-up process.

1. The volume is divided into leaf nodes (e.g., $2 \\times 2 \\times 2$ blocks).  
2. Unique leaf nodes are stored in a hash map.  
3. The next level of the tree is constructed by referencing these unique leaves.  
4. This process repeats up to the root.

The compression ratios achieved by SVDAGs are immense. A high-resolution voxel scene that would require gigabytes of VRAM in a raw grid can often be compressed into megabytes.18

#### **3.2.2 The Physics Incompatibility**

Despite its efficiency, the SVDAG is fundamentally **immutable**. Because multiple parents share the same child, modifying a child node affects every instance of that geometry in the world. If you break a block on one pillar, every identical pillar would instantaneously break in the same spot.17 While recent research (such as the **Aokana** framework 19) proposes methods for GPU-driven updates to SVDAGs via "dirty tagging" and localized reconstruction, it remains a rendering-focused structure rather than a physics-focused one.

### **3.3 The Brickmap: The Industrial Standard for Dynamics**

For engines like *Teardown* and *Octo*, which require arbitrary, persistent destruction and physics, the **Brickmap** (or Hierarchical 3D Texture) is the preferred data structure.21

#### **3.3.1 Architecture of a Brickmap**

The Brickmap strikes a balance between the compression of an octree and the speed of a flat grid.

* **The Indirection Grid:** A coarse 3D texture (e.g., $N \\times N \\times N$) where each entry represents a large region of space (a "chunk"). The value stored here is not material data, but an **index** or pointer. (In lattice-based projects, this grid is storage/tiling only.)
* **The Brick Atlas:** A massive, linear 3D texture (e.g., $4096 \\times 4096 \\times 256$) allocated in VRAM. This atlas is subdivided into smaller "Bricks" (e.g., $32 \\times 32 \\times 32$ voxel blocks).22

When a ray traverses the world, or a physics body queries a collision:

1. It samples the Indirection Grid at the global coordinate.  
2. If the value is NULL, the region is empty, and the ray skips the entire chunk ($O(1)$ skipping).  
3. If the value is a valid index, it maps to a specific coordinate in the Brick Atlas.  
4. The shader then samples the detailed voxel data from the Atlas.

#### **3.3.2 Why It Wins for Physics**

The Brickmap allows for **$O(1)$ read/write access**. A physics thread calculating a collision does not need to traverse a tree; it performs one texture fetch to find the brick index and a second fetch to get the voxel data. Writing to the world (destruction) is simply a standard texture write operation. This structure also leverages the GPU's native texture caching and trilinear filtering hardware, which SVOs and DAGs cannot.21

### **3.4 Hash Grids: Infinite Worlds**

For open-world scenarios where the bounds are unknown, Hash Grids offer an alternative.23 Instead of a 3D texture, the world is stored in a 1D buffer accessed via a spatial hash function:

$$Index \= (x \\cdot P\_1 \\oplus y \\cdot P\_2 \\oplus z \\cdot P\_3) \\mod TableSize$$

While this allows for infinite worlds, hash collisions and the lack of memory locality (neighboring voxels in 3D space are rarely neighbors in VRAM) introduce significant cache misses, often making them slower than Brickmaps for dense volumetric simulations.15

## ---

**4\. Physics Implementation Details**

Simulating the interaction between granular matter and rigid bodies is the most complex aspect of these engines. It requires bridging the gap between discrete voxel data and continuous mathematical surfaces.

### **4.1 Granular Fluid Dynamics**

The simulation of "fluids" in voxel engines (water, smoke, fire) is typically an approximation using **Cellular Automata** rather than true Navier-Stokes fluid dynamics.

#### **4.1.1 The "Sand" Algorithm**

The logic, derived from 2D engines like *Noita* but expanded to 3D, follows a specific hierarchy of checks 9:

1. **Gravity:** Check the voxel directly below $(x, y-1, z)$. If empty, swap.  
2. **Dispersion:** If below is occupied, check diagonals $(x\\pm1, y-1, z)$ and $(x, y-1, z\\pm1)$.  
3. **Density Check:** If the voxel below is a liquid and the current voxel is a solid (sand), swap them (sinking).

#### **4.1.2 Stochastic Behavior**

To avoid uniform, crystalline movement patterns (where sand piles form perfect pyramids), engines introduce stochasticity. The compute shader generates a pseudo-random number based on the voxel's coordinate and the frame count. This random value determines the preferred dispersion direction (e.g., checking left before right), resulting in organic, naturalistic piling behaviors.26

### **4.2 Rigid Body Coupling**

A critical requirement is the interaction between standard rigid bodies (boxes, spheres, character controllers) and the granular world.

#### **4.2.1 Signed Distance Field (SDF) Generation**

To allow a mesh to collide with voxels, the engine must know the distance from the mesh surface to the nearest voxel. High-performance engines generate a **Signed Distance Field (SDF)** from the voxel grid.27

* **Jump Flooding Algorithm (JFA):** This GPU algorithm propagates distance information across the grid in logarithmic steps. It allows the engine to generate a distance map for the entire voxel world in a few milliseconds.29  
* **Collision Resolution:** The rigid body samples this SDF. If the distance is negative, a penetration has occurred. The gradient of the SDF at that point gives the collision normal, and the value gives the penetration depth. This allows for robust, continuous collision detection without converting voxels to meshes.30

#### **4.2.2 Voxmap-PointShell (VPS)**

An alternative method, used in haptic rendering and likely in parts of *Teardown*, is the **Voxmap-PointShell** algorithm.31 The rigid body is represented by a cloud of points (the "shell"). In every physics step, each point queries the voxel grid (the "voxmap").

* If a point is inside a solid voxel, a penalty force is applied to the rigid body at that point, opposite to its velocity.  
* This method is extremely fast for complex concave shapes but can suffer from "tunneling" if the object moves faster than the voxel size per frame.

### **4.3 Structural Integrity and Connectivity Graphs**

One of the most defining features of *Teardown* is that objects are not just piles of voxels; they are structural entities. A house stands because the voxels are connected. If the walls are destroyed, the roof should fall.

#### **4.3.1 The Flood-Fill Algorithm**

To achieve this, the engine maintains a **Connectivity Graph**.

* **Nodes:** Chunks or clusters of voxels.  
* **Edges:** Adjacency between chunks.  
* **Ground:** Special nodes that are static (terrain).

When a voxel is removed (destruction event), the engine marks the local chunk as "dirty." A **Breadth-First Search (BFS)** or Flood-Fill algorithm runs to check if a path still exists from the dirty chunk to a Ground node.32

#### **4.3.2 Optimization: Time-Slicing**

Running a global flood-fill on a graph with thousands of nodes is too slow for a single frame. *Teardown* optimizes this by **Time-Slicing** the update.34 The BFS is spread across multiple frames. The structural integrity might not be resolved instantly; a floating island might hang in the air for 100-200ms before the algorithm detects the disconnection and wakes up the physics island. This latency is usually imperceptible to the player amidst the chaos of destruction.

## ---

**5\. Rendering Integration: Raytracing the Volume**

The rendering of granular worlds poses a unique challenge: the geometry is too dense for rasterization. Generating a triangle mesh (via Marching Cubes) for a dynamic world of 1 billion voxels is computationally infeasible due to the cost of vertex buffer generation and upload.2

### **5.1 Software Raymarching**

Consequently, almost all high-fidelity voxel engines utilize **Software Raymarching** implemented in Compute Shaders or Fragment Shaders.21

#### **5.1.1 The DDA Algorithm**

The Digital Differential Analyzer (DDA) is the standard algorithm for traversing a grid. It steps the ray forward one voxel unit at a time.

* **Setup:** Calculate tDelta (distance to next x/y/z boundary) and step (sign of direction).  
* **Loop:** Increment the shortest axis, sample the grid, break if solid.

#### **5.1.2 Hierarchical Traversal**

To optimize DDA, engines utilize the Brickmap structure. The ray first traverses the **Indirection Grid**.

* **Empty Space Skipping:** If the ray is in an empty chunk, it steps forward by the size of the chunk (e.g., 32 units) in a single iteration.  
* **Refinement:** Only when it hits a populated chunk does it switch to the fine-grained DDA to intersect individual voxels. This hierarchical traversal reduces the number of memory fetches from thousands to dozens per pixel.36

### **5.2 Lighting and Global Illumination**

Since the geometry is volumetric, standard baked lighting is impossible.

#### **5.2.1 Flood-Fill Lighting (Minecraft Style)**

For simple propagation, a BFS algorithm spreads light values from emitters (sun, torches) through empty voxels.37 This is fast but lacks shadows and directional occlusion.

#### **5.2.2 Path Tracing (John Lin Style)**

John Lin’s engine and *Teardown* push visual fidelity by implementing **Path Tracing**.21

* **Direct Light:** Raytrace from the surface to the light source (sun).  
* **Indirect Light (GI):** Cast random rays from the surface into the hemisphere to sample the surrounding voxel colors.  
* **Denoising:** Because real-time path tracing produces noisy images (fireflies), these engines rely heavily on **Temporal Accumulation** (reusing samples from previous frames) and spatial denoising filters (blurring noise while preserving edges) to produce a clean image.35

## ---

**6\. Major Technical Bottlenecks**

Despite the impressive demos, several critical bottlenecks prevent granular voxel engines from becoming the standard in AAA game development.

### **6.1 The PCIe Bus Latency (The "Readback" Problem)**

This is the most significant architectural hurdle.

* **The Problem:** The simulation resides entirely on the GPU. However, game logic (AI pathfinding, mission triggers, audio systems) typically resides on the CPU.  
* **The Bottleneck:** To update the CPU logic, the voxel data must be copied from VRAM to system RAM. The PCIe bus bandwidth is limited (approx. 16-32 GB/s), and the latency of a glReadPixels or AsyncGPUReadback operation introduces a delay of 2-3 frames.1  
* **Impact:** This latency makes tight gameplay loops difficult. If a player shoots an enemy, the physics engine knows the enemy is dead on Frame 1, but the CPU logic might not know until Frame 4\. This de-synchronization leads to "ghost" collisions and unresponsive AI.

### **6.2 Memory Fragmentation and Bandwidth**

* **VRAM Limits:** A uncompressed $2048^3$ grid of 8-bit voxels requires 8GB of VRAM. With double-buffering (for physics) and normal maps/material data, this bloats to 32GB+, exceeding consumer hardware.  
* **Bandwidth Saturation:** Compute shaders modifying millions of voxels consume massive memory bandwidth. If the memory controller is saturated by the physics simulation, there is no bandwidth left for the rendering pass, causing frame rate drops even if the compute cores are not fully utilized.39

### **6.3 Determinism and Networking**

* **Floating Point Drift:** GPU floating-point operations are not strictly deterministic across different architectures (e.g., an NVIDIA RTX 3080 vs an AMD RX 6800).  
* **Multiplayer Impossibility:** Because the simulation cannot be perfectly replicated on different clients, the only way to synchronize multiplayer is to send the *state* of the voxels. Sending the delta-compression of a billion dynamic voxels over the internet is bandwidth-prohibitive. This restricts most granular physics games (like *Teardown* and *Noita*) to single-player experiences.40

## ---

**7\. State of the Art: Ecosystem and Case Studies**

### **7.1 Teardown (Tuxedo Labs)**

* **Approach:** Hybrid. Dynamic voxels for destruction, rigid bodies for debris.  
* **Key Innovation:** The use of **Brickmaps** to balance memory and update speed, and a specialized **Flood-Fill** algorithm for structural integrity that runs on the CPU, accepting the latency trade-off for complex graph analysis.21

### **7.2 John Lin’s Sandbox**

* **Approach:** Pure GPU Granular.  
* **Key Innovation:** Full unification of fluid and solid mechanics in a single compute pipeline. The rejection of SVOs in favor of raw grid/brickmap performance allows for the simulation of water pressure and soil erosion that *Teardown* cannot handle.5

### **7.3 Aokana Framework**

* **Approach:** GPU-Driven SVDAG.  
* **Key Innovation:** While mostly a rendering framework, it pushes the boundary of **streaming** massive voxel worlds. It demonstrates that SVDAGs can be updated dynamically if the updates are localized, challenging the notion that DAGs are strictly for static data.19

### **7.4 Promising Repositories**

For developers looking to dissect code, the following repositories represent the current cutting edge:

| Repository | Technology | Relevance |
| :---- | :---- | :---- |
| **DouglasDwyer/octo-release** 29 | Rust, WGPU, SAT Physics | Best open-source example of rigid-body-to-voxel coupling. |
| **stijnherfst/BrickMap** 22 | C++, OpenGL | Reference implementation of the Brickmap data structure. |
| **voxcraft-sim** 41 | CUDA | High-performance granular physics kernels. |
| **Phyronnaz/HashDAG** 14 | C++ | Advanced SVDAG compression algorithms. |

## ---

**8\. Conclusion**

The state of the art in granular voxel physics requires a fundamental departure from traditional game engine architecture. It demands a move to a **GPU-centric ecosystem** where the CPU is relegated to a dispatcher role. The most successful implementations, such as *Teardown* and John Lin’s sandbox, achieve their results by rejecting standard sparse structures like SVOs in favor of **Brickmaps** and **3D Textures** that support the massive bandwidth requirements of cellular automata.

While the "Holy Grail" of a fully interactive, multiplayer, infinite voxel world remains elusive due to PCIe bottlenecks and network bandwidth limits, the techniques pioneered by these developers—Indirect Dispatch, Active Voxel Lists, and Software Raymarching—have laid the foundation for the next generation of physics engines. As hardware evolves towards **Mesh Shaders** and unified memory architectures, the boundary between the simulation of light (rendering) and the simulation of matter (physics) will continue to dissolve, bringing us closer to truly granular virtual worlds.

## **9\. Appendix: Data Structures & Algorithms Comparison**

### **Table 1: Voxel Data Structures for Granular Physics**

| Feature | Sparse Voxel Octree (SVO) | Sparse Voxel DAG (SVDAG) | Brickmap (3D Texture Atlas) | Hash Grid |
| :---- | :---- | :---- | :---- | :---- |
| **Memory Efficiency** | High (Sparse) | **Very High (Deduplication)** | Moderate (Atlas Overhead) | High (Sparse) |
| **Read Speed (Render)** | $O(\\log N)$ \- Slow | $O(\\log N)$ \- Slow | **$O(1)$ \- Fast** | $O(1)$ \- Fast (with collisions) |
| **Write Speed (Physics)** | **Very Slow** (Rebalancing) | **Impossible/Slow** (Immutable) | **Fast** (Texture Write) | Moderate (Hash Collisions) |
| **GPU Cache Locality** | Poor (Pointer Chasing) | Poor (Pointer Chasing) | **Excellent** (Texture Cache) | Poor (Random Access) |
| **Primary Use Case** | Static Geometry | Static/Compressed Geometry | **Dynamic Physics/Destruction** | Infinite/Sparse Particles |

### **Table 2: Physics Simulation Paradigms**

| Paradigm | Rigid Body Dynamics | Cellular Automata (CA) | Material Point Method (MPM) |
| :---- | :---- | :---- | :---- |
| **Description** | Objects are solid hulls. | Objects are grid cells reacting to neighbors. | Objects are particles tracked in a grid. |
| **Strengths** | Stable, Fast, Standard. | Emergent behavior (fluids, fire). | Accurate continuum mechanics. |
| **Weaknesses** | No internal deformation. | Grid bias, Mass conservation issues. | Extremely expensive compute. |
| **Typical Engine** | *PhysX, Havok* | *Noita, Falling Sand* | *Disney Frozen (Offline)* |
| **Voxel Suitability** | Low (Requires meshing) | **High (Native to grid)** | Medium (Hybrid) |

### **Table 3: Collision Detection Approaches**

| Method | Mesh-Based (Convex Hull) | Voxmap-PointShell (VPS) | Signed Distance Field (SDF) |
| :---- | :---- | :---- | :---- |
| **Concept** | Standard game physics. | Point cloud queries voxel grid. | Raymarching the distance field. |
| **Performance** | Fast for simple shapes. | Fast for complex/concave shapes. | **Very Fast** on GPU. |
| **Accuracy** | Approximation. | High (depends on point density). | Very High. |
| **Dynamic Update** | Slow (Convex Decomposition). | **Instant** (No pre-processing). | Slow (Re-calculating SDF). |
| **Best For** | Static debris. | **Dynamic voxel destruction.** | Soft bodies / Deformables. |

#### **Works cited**

1. Does making a falling sand simulator in compute shaders even make sense? \- Reddit, accessed December 31, 2025, [https://www.reddit.com/r/GraphicsProgramming/comments/1jvq0ah/does\_making\_a\_falling\_sand\_simulator\_in\_compute/](https://www.reddit.com/r/GraphicsProgramming/comments/1jvq0ah/does_making_a_falling_sand_simulator_in_compute/)  
2. jedjoud10/VoxelTerrain: Voxel Terrain Generator for Unity ECS \- GitHub, accessed December 31, 2025, [https://github.com/jedjoud10/VoxelTerrain](https://github.com/jedjoud10/VoxelTerrain)  
3. Streaming voxels in real time while rendering : r/VoxelGameDev \- Reddit, accessed December 31, 2025, [https://www.reddit.com/r/VoxelGameDev/comments/1ml3l7o/streaming\_voxels\_in\_real\_time\_while\_rendering/](https://www.reddit.com/r/VoxelGameDev/comments/1ml3l7o/streaming_voxels_in_real_time_while_rendering/)  
4. Resources on dynamically updating a GPU-based sparse voxel octree? \- Reddit, accessed December 31, 2025, [https://www.reddit.com/r/VoxelGameDev/comments/1dfcmzd/resources\_on\_dynamically\_updating\_a\_gpubased/](https://www.reddit.com/r/VoxelGameDev/comments/1dfcmzd/resources_on_dynamically_updating_a_gpubased/)  
5. The Perfect Voxel Engine \- John Lin's Thoughts, accessed December 31, 2025, [https://voxely.net/blog/the-perfect-voxel-engine/](https://voxely.net/blog/the-perfect-voxel-engine/)  
6. Implementing Cellular Automata with Compute Shaders in Unity, accessed December 31, 2025, [https://ift.devinci.fr/tutorial/Cellular-Automata-with-Shaders](https://ift.devinci.fr/tutorial/Cellular-Automata-with-Shaders)  
7. Cellular Automata on compute shader. : r/proceduralgeneration \- Reddit, accessed December 31, 2025, [https://www.reddit.com/r/proceduralgeneration/comments/1231wvl/cellular\_automata\_on\_compute\_shader/](https://www.reddit.com/r/proceduralgeneration/comments/1231wvl/cellular_automata_on_compute_shader/)  
8. "Just falling sand" cellular-automata running at 20000 FPS for 1600x900 cells \- Reddit, accessed December 31, 2025, [https://www.reddit.com/r/cellular\_automata/comments/1f2ii2b/just\_falling\_sand\_cellularautomata\_running\_at/](https://www.reddit.com/r/cellular_automata/comments/1f2ii2b/just_falling_sand_cellularautomata_running_at/)  
9. Optimizing falling sand simulation \- Game Development Stack Exchange, accessed December 31, 2025, [https://gamedev.stackexchange.com/questions/183379/optimizing-falling-sand-simulation](https://gamedev.stackexchange.com/questions/183379/optimizing-falling-sand-simulation)  
10. GPU Falling sand simulation using block cellular automata \- GitHub, accessed December 31, 2025, [https://github.com/GelamiSalami/GPU-Falling-Sand-CA](https://github.com/GelamiSalami/GPU-Falling-Sand-CA)  
11. Compute shaders : r/VoxelGameDev \- Reddit, accessed December 31, 2025, [https://www.reddit.com/r/VoxelGameDev/comments/pljbyv/compute\_shaders/](https://www.reddit.com/r/VoxelGameDev/comments/pljbyv/compute_shaders/)  
12. Scripting API: ComputeShader.DispatchIndirect \- Unity \- Manual, accessed December 31, 2025, [https://docs.unity3d.com/6000.3/Documentation/ScriptReference/ComputeShader.DispatchIndirect.html](https://docs.unity3d.com/6000.3/Documentation/ScriptReference/ComputeShader.DispatchIndirect.html)  
13. Pass:compute \- LÖVR, accessed December 31, 2025, [https://lovr.org/docs/Pass:compute](https://lovr.org/docs/Pass:compute)  
14. Does anyone know what technique John Lin uses for his micro voxels? \- Reddit, accessed December 31, 2025, [https://www.reddit.com/r/GraphicsProgramming/comments/s3npig/does\_anyone\_know\_what\_technique\_john\_lin\_uses\_for/](https://www.reddit.com/r/GraphicsProgramming/comments/s3npig/does_anyone_know_what_technique_john_lin_uses_for/)  
15. Are sparse voxel octrees really (always) the best voxel data structure? : r/VoxelGameDev, accessed December 31, 2025, [https://www.reddit.com/r/VoxelGameDev/comments/1jb8uol/are\_sparse\_voxel\_octrees\_really\_always\_the\_best/](https://www.reddit.com/r/VoxelGameDev/comments/1jb8uol/are_sparse_voxel_octrees_really_always_the_best/)  
16. High Resolution Sparse Voxel DAGs, accessed December 31, 2025, [https://icg.gwu.edu/sites/g/files/zaxdzs6126/files/downloads/highResolutionSparseVoxelDAGs.pdf](https://icg.gwu.edu/sites/g/files/zaxdzs6126/files/downloads/highResolutionSparseVoxelDAGs.pdf)  
17. Sparse Voxel DAGs \- Chalmers Publication Library, accessed December 31, 2025, [https://publications.lib.chalmers.se/records/fulltext/240766/240766.pdf](https://publications.lib.chalmers.se/records/fulltext/240766/240766.pdf)  
18. High Resolution Sparse Voxel DAGs \- Page has been moved, accessed December 31, 2025, [https://www.cse.chalmers.se/\~uffe/HighResolutionSparseVoxelDAGs.pdf](https://www.cse.chalmers.se/~uffe/HighResolutionSparseVoxelDAGs.pdf)  
19. Aokana: A GPU-Driven Voxel Rendering Framework for Open World Games \- arXiv, accessed December 31, 2025, [https://arxiv.org/abs/2505.02017](https://arxiv.org/abs/2505.02017)  
20. Aokana: A GPU-Driven Voxel Rendering Framework for Open World Games \- ResearchGate, accessed December 31, 2025, [https://www.researchgate.net/publication/392803107\_Aokana\_A\_GPU-Driven\_Voxel\_Rendering\_Framework\_for\_Open\_World\_Games](https://www.researchgate.net/publication/392803107_Aokana_A_GPU-Driven_Voxel_Rendering_Framework_for_Open_World_Games)  
21. Teardown Frame Teardown \- Acko.net, accessed December 31, 2025, [https://acko.net/blog/teardown-frame-teardown/](https://acko.net/blog/teardown-frame-teardown/)  
22. stijnherfst/BrickMap: A high performance realtime CUDA voxel path tracer \- GitHub, accessed December 31, 2025, [https://github.com/stijnherfst/BrickMap](https://github.com/stijnherfst/BrickMap)  
23. Why are oct trees so much more common than hash tables?, accessed December 31, 2025, [https://computergraphics.stackexchange.com/questions/8364/why-are-oct-trees-so-much-more-common-than-hash-tables](https://computergraphics.stackexchange.com/questions/8364/why-are-oct-trees-so-much-more-common-than-hash-tables)  
24. Large Scale 3D Modelling via Sparse Volumes, accessed December 31, 2025, [https://elib.dlr.de/96351/1/FunkBoernerv1.pdf](https://elib.dlr.de/96351/1/FunkBoernerv1.pdf)  
25. Exploring the Tech and Design of 'Noita' \- GDC Vault, accessed December 31, 2025, [https://www.gdcvault.com/play/1025695/Exploring-the-Tech-and-Design](https://www.gdcvault.com/play/1025695/Exploring-the-Tech-and-Design)  
26. How to Code a Falling Sand Simulation \- High Level Concept Video : r/programming, accessed December 31, 2025, [https://www.reddit.com/r/programming/comments/njeyuz/how\_to\_code\_a\_falling\_sand\_simulation\_high\_level/](https://www.reddit.com/r/programming/comments/njeyuz/how_to_code_a_falling_sand_simulation_high_level/)  
27. Deferred Signed Distance Field rendering \- Interplay of Light \- WordPress.com, accessed December 31, 2025, [https://interplayoflight.wordpress.com/2017/12/12/deferred-signed-distance-field-rendering/](https://interplayoflight.wordpress.com/2017/12/12/deferred-signed-distance-field-rendering/)  
28. Local Optimization for Robust Signed Distance Field Collision \- YouTube, accessed December 31, 2025, [https://www.youtube.com/watch?v=icU6Bm-HZ-E](https://www.youtube.com/watch?v=icU6Bm-HZ-E)  
29. DouglasDwyer/octo-release: The Octo voxel game engine \- GitHub, accessed December 31, 2025, [https://github.com/DouglasDwyer/octo-release](https://github.com/DouglasDwyer/octo-release)  
30. Real-time Collision Detection between General SDFs, accessed December 31, 2025, [http://www.cad.zju.edu.cn/home/jin/papers/Real\_Time\_CD\_between\_SDFs.pdf](http://www.cad.zju.edu.cn/home/jin/papers/Real_Time_CD_between_SDFs.pdf)  
31. Collision detection between triangle and voxel using the Separating Axis Theorem (SAT). Red \- ResearchGate, accessed December 31, 2025, [https://www.researchgate.net/figure/Collision-detection-between-triangle-and-voxel-using-the-Separating-Axis-Theorem-SAT\_fig2\_224990152](https://www.researchgate.net/figure/Collision-detection-between-triangle-and-voxel-using-the-Separating-Axis-Theorem-SAT_fig2_224990152)  
32. Support on Optimizing Voxel-Based Flood Fill Algorithm \- Developer Forum | Roblox, accessed December 31, 2025, [https://devforum.roblox.com/t/support-on-optimizing-voxel-based-flood-fill-algorithm/3941551](https://devforum.roblox.com/t/support-on-optimizing-voxel-based-flood-fill-algorithm/3941551)  
33. Structural Integrity approach with Voxels : r/VoxelGameDev \- Reddit, accessed December 31, 2025, [https://www.reddit.com/r/VoxelGameDev/comments/ng30fn/structural\_integrity\_approach\_with\_voxels/](https://www.reddit.com/r/VoxelGameDev/comments/ng30fn/structural_integrity_approach_with_voxels/)  
34. Structural Integrity & Collateral Damage System \- Steam Community, accessed December 31, 2025, [https://steamcommunity.com/sharedfiles/filedetails/?id=2598660254](https://steamcommunity.com/sharedfiles/filedetails/?id=2598660254)  
35. Teardown Teardown \- Blog, accessed December 31, 2025, [https://juandiegomontoya.github.io/teardown\_breakdown.html](https://juandiegomontoya.github.io/teardown_breakdown.html)  
36. State-of-the-Art in GPU-Based Large-Scale Volume Visualization \- Johanna Beyer, accessed December 31, 2025, [https://johanna-b.github.io/files/documents/STAR\_CGF\_GPULargeScaleVolVis.pdf](https://johanna-b.github.io/files/documents/STAR_CGF_GPULargeScaleVolVis.pdf)  
37. Fast Flood Fill Lighting in a Blocky Voxel Game: Pt 1 : r/VoxelGameDev \- Reddit, accessed December 31, 2025, [https://www.reddit.com/r/VoxelGameDev/comments/2irqei/fast\_flood\_fill\_lighting\_in\_a\_blocky\_voxel\_game/](https://www.reddit.com/r/VoxelGameDev/comments/2irqei/fast_flood_fill_lighting_in_a_blocky_voxel_game/)  
38. What is the feasibility of Compute Shader-generated voxel terrain? : r/Unity3D \- Reddit, accessed December 31, 2025, [https://www.reddit.com/r/Unity3D/comments/kewxkn/what\_is\_the\_feasibility\_of\_compute/](https://www.reddit.com/r/Unity3D/comments/kewxkn/what_is_the_feasibility_of_compute/)  
39. Efficient Sparse Voxel Octrees – Analysis, Extensions, and Implementation \- Research at NVIDIA, accessed December 31, 2025, [https://research.nvidia.com/sites/default/files/pubs/2010-02\_Efficient-Sparse-Voxel/laine2010tr1\_paper.pdf](https://research.nvidia.com/sites/default/files/pubs/2010-02_Efficient-Sparse-Voxel/laine2010tr1_paper.pdf)  
40. Teardown and Voxel-Based Rendering with Dennis Gustafsson, accessed December 31, 2025, [https://softwareengineeringdaily.com/2025/01/02/teardown-and-voxel-based-rendering-with-dennis-gustafsson/](https://softwareengineeringdaily.com/2025/01/02/teardown-and-voxel-based-rendering-with-dennis-gustafsson/)  
41. voxcraft/voxcraft-sim: a GPU-accelerated voxel-based physics engine \- GitHub, accessed December 31, 2025, [https://github.com/voxcraft/voxcraft-sim](https://github.com/voxcraft/voxcraft-sim)
