const canvas = document.querySelector("#viewport");
const hint = document.querySelector(".hint");

const gridWidth = 96;
const gridHeight = 64;
const gridDepth = 96;

const MAT_EMPTY = 0;
const MAT_SAND = 1;
const MAT_WALL = 2;
const MAT_MASK = 3;
const ACTIVE_MASK = 4;
const VACUUM_MASK = 8;
const VACUUM_MOVED = 16;

const TOOL_NONE = 0;
const TOOL_HAMMER = 1;
const TOOL_VACUUM = 2;
const TOOL_PLACE = 3;

if (!navigator.gpu) {
  hint.textContent = "WebGPU not supported in this browser.";
  throw new Error("WebGPU not supported.");
}

const adapter = await navigator.gpu.requestAdapter();
const device = await adapter.requestDevice();

const context = canvas.getContext("webgpu");
const format = navigator.gpu.getPreferredCanvasFormat();
context.configure({ device, format, alphaMode: "premultiplied" });

const cellCount = gridWidth * gridHeight * gridDepth;
const stateBytes = cellCount * Uint32Array.BYTES_PER_ELEMENT;

const stateA = device.createBuffer({
  size: stateBytes,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
});
const stateB = device.createBuffer({
  size: stateBytes,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
});

const initState = new Uint32Array(cellCount);

const idx = (x, y, z) => x + y * gridWidth + z * gridWidth * gridHeight;

for (let z = 0; z < gridDepth; z += 1) {
  for (let x = 0; x < gridWidth; x += 1) {
    initState[idx(x, 0, z)] = MAT_WALL;
  }
}

const blockSize = 8;
const blockStartX = Math.floor(gridWidth / 2 - blockSize / 2);
const blockStartY = 1;
const blockStartZ = Math.floor(gridDepth / 2 - blockSize / 2);

for (let z = 0; z < blockSize; z += 1) {
  for (let y = 0; y < blockSize; y += 1) {
    for (let x = 0; x < blockSize; x += 1) {
      const ix = blockStartX + x;
      const iy = blockStartY + y;
      const iz = blockStartZ + z;
      initState[idx(ix, iy, iz)] = MAT_SAND;
    }
  }
}

device.queue.writeBuffer(stateA, 0, initState);
device.queue.writeBuffer(stateB, 0, initState);

const paramBuffer = device.createBuffer({
  size: 144,
  usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
});

const countBuffer = device.createBuffer({
  size: 48,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST,
});
const countReadBuffer = device.createBuffer({
  size: 48,
  usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
});

const computeShader = device.createShaderModule({
  code: `
struct Params {
  grid : vec4<u32>,
  camPos : vec4<f32>,
  camDir : vec4<f32>,
  camRight : vec4<f32>,
  camUp : vec4<f32>,
  screen : vec4<f32>,
  swing : vec4<f32>,
  tool : vec4<u32>,
  vacuum : vec4<f32>,
};

struct Counts {
  vacuum : atomic<u32>,
  placed : atomic<u32>,
  tagged : atomic<u32>,
  moved : atomic<u32>,
  vacuumedSeen : atomic<u32>,
  vacuumedDeleted : atomic<u32>,
};

@group(0) @binding(0) var<storage, read> stateIn : array<u32>;
@group(0) @binding(1) var<storage, read_write> stateOut : array<u32>;
@group(0) @binding(2) var<uniform> params : Params;
@group(0) @binding(3) var<storage, read_write> counts : Counts;

const MAT_EMPTY : u32 = 0u;
const MAT_SAND : u32 = 1u;
const MAT_WALL : u32 = 2u;
const MAT_MASK : u32 = 3u;
const ACTIVE_MASK : u32 = 4u;
const VACUUM_MASK : u32 = 8u;
const VACUUM_MOVED : u32 = 16u;

fn idx(x : i32, y : i32, z : i32) -> u32 {
  return u32(x) + u32(y) * params.grid.x + u32(z) * params.grid.x * params.grid.y;
}

fn inBounds(x : i32, y : i32, z : i32) -> bool {
  return x >= 0 && y >= 0 && z >= 0 && x < i32(params.grid.x) && y < i32(params.grid.y) && z < i32(params.grid.z);
}

fn getCell(x : i32, y : i32, z : i32) -> u32 {
  if (!inBounds(x, y, z)) {
    return MAT_WALL;
  }
  return stateIn[idx(x, y, z)];
}

fn hash(x : u32, y : u32, z : u32, frame : u32) -> u32 {
  var h = x * 374761393u + y * 668265263u + z * 2246822519u + frame * 3266489917u;
  h = (h ^ (h >> 13u)) * 1274126177u;
  return h ^ (h >> 16u);
}

fn swingInside(x : i32, y : i32, z : i32) -> bool {
  if (params.swing.w <= 0.0) {
    return false;
  }
  let dx = f32(x) + 0.5 - params.swing.x;
  let dy = f32(y) + 0.5 - params.swing.y;
  let dz = f32(z) + 0.5 - params.swing.z;
  return dx * dx + dy * dy + dz * dz <= params.swing.w * params.swing.w;
}

fn activeFor(x : i32, y : i32, z : i32, cell : u32) -> bool {
  if ((cell & MAT_MASK) != MAT_SAND) {
    return false;
  }
  if ((cell & VACUUM_MASK) != 0u) {
    return true;
  }
  if ((cell & ACTIVE_MASK) != 0u) {
    return true;
  }
  let below = getCell(x, y - 1, z);
  return (below & MAT_MASK) == MAT_EMPTY;
}

fn vacuumDir(x : i32, y : i32, z : i32) -> vec3<i32> {
  let aim = params.vacuum.xyz;
  let pos = vec3<f32>(f32(x) + 0.5, f32(y) + 0.5, f32(z) + 0.5);
  let dir = aim - pos;
  let adir = abs(dir);
  var step = vec3<i32>(0, 0, 0);
  var primary = vec3<i32>(0, 0, 0);
  var secondary = vec3<i32>(0, 0, 0);
  var tertiary = vec3<i32>(0, 0, 0);

  if (adir.x >= adir.y && adir.x >= adir.z) {
    primary = vec3<i32>(select(-1, 1, dir.x >= 0.0), 0, 0);
    secondary = vec3<i32>(0, select(-1, 1, dir.y >= 0.0), 0);
    tertiary = vec3<i32>(0, 0, select(-1, 1, dir.z >= 0.0));
  } else if (adir.y >= adir.z) {
    primary = vec3<i32>(0, select(-1, 1, dir.y >= 0.0), 0);
    secondary = vec3<i32>(select(-1, 1, dir.x >= 0.0), 0, 0);
    tertiary = vec3<i32>(0, 0, select(-1, 1, dir.z >= 0.0));
  } else {
    primary = vec3<i32>(0, 0, select(-1, 1, dir.z >= 0.0));
    secondary = vec3<i32>(select(-1, 1, dir.x >= 0.0), 0, 0);
    tertiary = vec3<i32>(0, select(-1, 1, dir.y >= 0.0), 0);
  }

  step = primary;
  var nx = x + step.x;
  var ny = y + step.y;
  var nz = z + step.z;
  if ((getCell(nx, ny, nz) & MAT_MASK) == MAT_EMPTY) {
    return step;
  }

  step = secondary;
  nx = x + step.x;
  ny = y + step.y;
  nz = z + step.z;
  if ((getCell(nx, ny, nz) & MAT_MASK) == MAT_EMPTY) {
    return step;
  }

  step = tertiary;
  nx = x + step.x;
  ny = y + step.y;
  nz = z + step.z;
  if ((getCell(nx, ny, nz) & MAT_MASK) == MAT_EMPTY) {
    return step;
  }

  return vec3<i32>(0, 0, 0);
}

fn moveDir(x : i32, y : i32, z : i32, cell : u32) -> vec3<i32> {
  if ((cell & MAT_MASK) != MAT_SAND) {
    return vec3<i32>(0, 0, 0);
  }
  if (!activeFor(x, y, z, cell)) {
    return vec3<i32>(0, 0, 0);
  }
  if ((cell & VACUUM_MASK) != 0u) {
    return vacuumDir(x, y, z);
  }
  let below = getCell(x, y - 1, z);
  if ((below & MAT_MASK) == MAT_EMPTY) {
    return vec3<i32>(0, -1, 0);
  }

  let r = i32(hash(u32(x), u32(y), u32(z), params.grid.x + params.grid.y + params.grid.z + params.grid.w) & 3u);
  let dx = array<i32, 4>(-1, 1, 0, 0);
  let dz = array<i32, 4>(0, 0, -1, 1);
  for (var i = 0; i < 4; i = i + 1) {
    let k = (i + r) & 3;
    let nx = x + dx[k];
    let nz = z + dz[k];
    let diag = getCell(nx, y - 1, nz);
    if ((diag & MAT_MASK) == MAT_EMPTY) {
      return vec3<i32>(dx[k], -1, dz[k]);
    }
  }

  return vec3<i32>(0, 0, 0);
}

fn wantsMove(srcX : i32, srcY : i32, srcZ : i32, dir : vec3<i32>) -> bool {
  if (!inBounds(srcX, srcY, srcZ)) {
    return false;
  }
  let cell = getCell(srcX, srcY, srcZ);
  if ((cell & MAT_MASK) != MAT_SAND) {
    return false;
  }
  let desire = moveDir(srcX, srcY, srcZ, cell);
  return all(desire == dir);
}

fn isVacuumed(srcX : i32, srcY : i32, srcZ : i32) -> bool {
  if (!inBounds(srcX, srcY, srcZ)) {
    return false;
  }
  let cell = getCell(srcX, srcY, srcZ);
  return (cell & VACUUM_MASK) != 0u;
}

@compute @workgroup_size(4, 4, 4)
fn simulate(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x >= params.grid.x || gid.y >= params.grid.y || gid.z >= params.grid.z) {
    return;
  }

  let x = i32(gid.x);
  let y = i32(gid.y);
  let z = i32(gid.z);
  let index = idx(x, y, z);
  var cell = getCell(x, y, z);
  var mat = cell & MAT_MASK;

  if (mat == MAT_WALL) {
    stateOut[index] = MAT_WALL;
    return;
  }

  if (params.tool.x == 2u && mat == MAT_SAND) {
    let pos = vec3<f32>(f32(x) + 0.5, f32(y) + 0.5, f32(z) + 0.5);
    let dist = distance(pos, params.vacuum.xyz);
    if (dist < params.vacuum.w * 2.0) {
      stateOut[index] = MAT_EMPTY;
      atomicAdd(&counts.vacuum, 1u);
      atomicAdd(&counts.vacuumedDeleted, 1u);
      return;
    }
  }

  if (params.tool.x == 1u && mat == MAT_SAND && swingInside(x, y, z)) {
    stateOut[index] = MAT_SAND | ACTIVE_MASK;
    return;
  }

  if (params.tool.x == 2u && mat == MAT_SAND && swingInside(x, y, z)) {
    cell = cell | VACUUM_MASK;
    atomicAdd(&counts.tagged, 1u);
  }

  if (params.tool.x == 3u && mat == MAT_EMPTY && swingInside(x, y, z)) {
    let slot = atomicAdd(&counts.placed, 1u);
    if (slot < params.tool.y) {
      stateOut[index] = MAT_SAND | ACTIVE_MASK;
    } else {
      atomicSub(&counts.placed, 1u);
    }
    return;
  }

  if (mat == MAT_SAND && (cell & VACUUM_MASK) != 0u) {
    atomicAdd(&counts.vacuumedSeen, 1u);
    let aim = params.vacuum.xyz;
    let pos = vec3<f32>(f32(x) + 0.5, f32(y) + 0.5, f32(z) + 0.5);
    let dist = distance(pos, aim);
    if (dist < params.vacuum.w * 2.0) {
      stateOut[index] = MAT_EMPTY;
      atomicAdd(&counts.vacuum, 1u);
      atomicAdd(&counts.vacuumedDeleted, 1u);
      return;
    }
    if (!swingInside(x, y, z)) {
      if ((params.grid.w & 3u) == 0u) {
        let dir = vacuumDir(x, y, z);
        if (!all(dir == vec3<i32>(0, 0, 0))) {
          let tx = x + dir.x;
          let ty = y + dir.y;
          let tz = z + dir.z;
          if ((getCell(tx, ty, tz) & MAT_MASK) != MAT_WALL) {
            let targetIndex = idx(tx, ty, tz);
            stateOut[targetIndex] = MAT_SAND | ACTIVE_MASK | VACUUM_MASK | VACUUM_MOVED;
            stateOut[index] = MAT_EMPTY;
            atomicAdd(&counts.moved, 1u);
            return;
          }
        }
      }
    }
  }

  {
    var incomingCount = 0u;
    var incoming = false;
    var incomingVacuum = false;
    let seed = hash(u32(x), u32(y), u32(z), params.grid.w);

    let fromAbove = wantsMove(x, y + 1, z, vec3<i32>(0, -1, 0));
    if (fromAbove) {
      incomingCount = incomingCount + 1u;
      if ((seed % incomingCount) == 0u) {
        incoming = true;
        incomingVacuum = isVacuumed(x, y + 1, z);
      }
    }

    let fromBelow = wantsMove(x, y - 1, z, vec3<i32>(0, 1, 0));
    if (fromBelow) {
      incomingCount = incomingCount + 1u;
      if ((seed % incomingCount) == 0u) {
        incoming = true;
        incomingVacuum = isVacuumed(x, y - 1, z);
      }
    }

    let fromLeft = wantsMove(x - 1, y, z, vec3<i32>(1, 0, 0));
    if (fromLeft) {
      incomingCount = incomingCount + 1u;
      if ((seed % incomingCount) == 0u) {
        incoming = true;
        incomingVacuum = isVacuumed(x - 1, y, z);
      }
    }

    let fromRight = wantsMove(x + 1, y, z, vec3<i32>(-1, 0, 0));
    if (fromRight) {
      incomingCount = incomingCount + 1u;
      if ((seed % incomingCount) == 0u) {
        incoming = true;
        incomingVacuum = isVacuumed(x + 1, y, z);
      }
    }

    let fromFront = wantsMove(x, y, z - 1, vec3<i32>(0, 0, 1));
    if (fromFront) {
      incomingCount = incomingCount + 1u;
      if ((seed % incomingCount) == 0u) {
        incoming = true;
        incomingVacuum = isVacuumed(x, y, z - 1);
      }
    }

    let fromBack = wantsMove(x, y, z + 1, vec3<i32>(0, 0, -1));
    if (fromBack) {
      incomingCount = incomingCount + 1u;
      if ((seed % incomingCount) == 0u) {
        incoming = true;
        incomingVacuum = isVacuumed(x, y, z + 1);
      }
    }

    let fromLeftDiag = wantsMove(x - 1, y + 1, z, vec3<i32>(1, -1, 0));
    if (fromLeftDiag) {
      incomingCount = incomingCount + 1u;
      if ((seed % incomingCount) == 0u) {
        incoming = true;
        incomingVacuum = isVacuumed(x - 1, y + 1, z);
      }
    }

    let fromRightDiag = wantsMove(x + 1, y + 1, z, vec3<i32>(-1, -1, 0));
    if (fromRightDiag) {
      incomingCount = incomingCount + 1u;
      if ((seed % incomingCount) == 0u) {
        incoming = true;
        incomingVacuum = isVacuumed(x + 1, y + 1, z);
      }
    }

    let fromFrontDiag = wantsMove(x, y + 1, z - 1, vec3<i32>(0, -1, 1));
    if (fromFrontDiag) {
      incomingCount = incomingCount + 1u;
      if ((seed % incomingCount) == 0u) {
        incoming = true;
        incomingVacuum = isVacuumed(x, y + 1, z - 1);
      }
    }

    let fromBackDiag = wantsMove(x, y + 1, z + 1, vec3<i32>(0, -1, -1));
    if (fromBackDiag) {
      incomingCount = incomingCount + 1u;
      if ((seed % incomingCount) == 0u) {
        incoming = true;
        incomingVacuum = isVacuumed(x, y + 1, z + 1);
      }
    }

    if (incoming) {
      if (incomingVacuum && mat == MAT_EMPTY) {
        stateOut[index] = MAT_SAND | ACTIVE_MASK | VACUUM_MASK | VACUUM_MOVED;
        atomicAdd(&counts.moved, 1u);
        return;
      }
      if (mat == MAT_EMPTY) {
        stateOut[index] = MAT_SAND | ACTIVE_MASK;
        return;
      }
    }
  }

  if (mat == MAT_SAND) {
    let dir = moveDir(x, y, z, cell);
    if (all(dir == vec3<i32>(0, 0, 0))) {
      let isActive = activeFor(x, y, z, cell);
      let keepVacuum = cell & VACUUM_MASK;
      let movedFlag = cell & VACUUM_MOVED;
      stateOut[index] = MAT_SAND | select(0u, ACTIVE_MASK, isActive) | keepVacuum | movedFlag;
      return;
    }
    stateOut[index] = MAT_EMPTY;
    return;
  }

  stateOut[index] = MAT_EMPTY;
}
`,
});

const renderShader = device.createShaderModule({
  code: `
struct Params {
  grid : vec4<u32>,
  camPos : vec4<f32>,
  camDir : vec4<f32>,
  camRight : vec4<f32>,
  camUp : vec4<f32>,
  screen : vec4<f32>,
  swing : vec4<f32>,
  tool : vec4<u32>,
  vacuum : vec4<f32>,
};

@group(0) @binding(0) var<storage, read> stateView : array<u32>;
@group(0) @binding(1) var<uniform> params : Params;

const MAT_EMPTY : u32 = 0u;
const MAT_SAND : u32 = 1u;
const MAT_WALL : u32 = 2u;
const MAT_MASK : u32 = 3u;

fn idx(x : i32, y : i32, z : i32) -> u32 {
  return u32(x) + u32(y) * params.grid.x + u32(z) * params.grid.x * params.grid.y;
}

fn inBounds(x : i32, y : i32, z : i32) -> bool {
  return x >= 0 && y >= 0 && z >= 0 && x < i32(params.grid.x) && y < i32(params.grid.y) && z < i32(params.grid.z);
}

fn sampleCell(p : vec3<i32>) -> u32 {
  if (!inBounds(p.x, p.y, p.z)) {
    return MAT_EMPTY;
  }
  return stateView[idx(p.x, p.y, p.z)];
}

struct VsOut {
  @builtin(position) position : vec4<f32>,
  @location(0) uv : vec2<f32>,
};

@vertex
fn vsMain(@builtin(vertex_index) vertexIndex : u32) -> VsOut {
  var pos = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -1.0),
    vec2<f32>(3.0, -1.0),
    vec2<f32>(-1.0, 3.0)
  );
  var uv = array<vec2<f32>, 3>(
    vec2<f32>(0.0, 1.0),
    vec2<f32>(2.0, 1.0),
    vec2<f32>(0.0, -1.0)
  );
  var out : VsOut;
  out.position = vec4<f32>(pos[vertexIndex], 0.0, 1.0);
  out.uv = uv[vertexIndex];
  return out;
}

fn intersectAABB(rayOrigin : vec3<f32>, rayDir : vec3<f32>, minB : vec3<f32>, maxB : vec3<f32>) -> vec2<f32> {
  let safeDir = select(vec3<f32>(0.0001), rayDir, abs(rayDir) > vec3<f32>(0.0001));
  let invDir = 1.0 / safeDir;
  let t0 = (minB - rayOrigin) * invDir;
  let t1 = (maxB - rayOrigin) * invDir;
  let tmin = max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z));
  let tmax = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
  return vec2<f32>(tmin, tmax);
}

fn intersectSphere(rayOrigin : vec3<f32>, rayDir : vec3<f32>, center : vec3<f32>, radius : f32) -> vec2<f32> {
  let oc = rayOrigin - center;
  let b = dot(oc, rayDir);
  let c = dot(oc, oc) - radius * radius;
  let h = b * b - c;
  if (h < 0.0) {
    return vec2<f32>(1e9, -1.0);
  }
  let t = -b - sqrt(h);
  let t2 = -b + sqrt(h);
  return vec2<f32>(t, t2);
}

@fragment
fn fsMain(input : VsOut) -> @location(0) vec4<f32> {
  let uv = clamp(input.uv, vec2<f32>(0.0), vec2<f32>(1.0));
  let px = (uv.x * 2.0 - 1.0) * params.screen.w;
  let py = (1.0 - uv.y * 2.0) * params.screen.z;
  let rayDir = normalize(params.camDir.xyz + params.camRight.xyz * px + params.camUp.xyz * py);
  let rayOrigin = params.camPos.xyz;

  let sphereCenter = params.vacuum.xyz;
  let sphereHit = intersectSphere(rayOrigin, rayDir, sphereCenter, params.vacuum.w);
  if (sphereHit.x > 0.0 && sphereHit.x < 1e8) {
    return vec4<f32>(0.2, 0.65, 0.95, 0.45);
  }

  let boundsMin = vec3<f32>(0.0, 0.0, 0.0);
  let boundsMax = vec3<f32>(f32(params.grid.x), f32(params.grid.y), f32(params.grid.z));
  let hit = intersectAABB(rayOrigin, rayDir, boundsMin, boundsMax);
  if (hit.y < max(hit.x, 0.0)) {
    return vec4<f32>(0.05, 0.06, 0.08, 1.0);
  }

  var t = max(hit.x, 0.0);
  var pos = rayOrigin + rayDir * t;
  var voxel = vec3<i32>(floor(pos));
  let step = select(vec3<i32>(-1, -1, -1), vec3<i32>(1, 1, 1), rayDir > vec3<f32>(0.0));

  let nextBoundary = vec3<f32>(
    f32(voxel.x + select(0, 1, rayDir.x > 0.0)),
    f32(voxel.y + select(0, 1, rayDir.y > 0.0)),
    f32(voxel.z + select(0, 1, rayDir.z > 0.0))
  );

  let safeDir = select(vec3<f32>(0.0001), rayDir, abs(rayDir) > vec3<f32>(0.0001));
  let invDir = 1.0 / safeDir;
  var tMax = (nextBoundary - pos) * invDir;
  let tDelta = abs(invDir);

  var normal = vec3<f32>(0.0);
  for (var i = 0; i < 256; i = i + 1) {
    if (!inBounds(voxel.x, voxel.y, voxel.z)) {
      break;
    }
    let cell = sampleCell(voxel);
    let mat = cell & MAT_MASK;
    if (mat != MAT_EMPTY) {
      let lightDir = normalize(vec3<f32>(0.4, 0.9, 0.2));
      let diffuse = max(dot(normalize(normal), lightDir), 0.2);
      let base = select(vec3<f32>(0.2, 0.23, 0.26), vec3<f32>(0.88, 0.70, 0.38), mat == MAT_SAND);
      let shade = base * diffuse;
      let fog = clamp(t / 160.0, 0.0, 0.6);
      let color = mix(shade, vec3<f32>(0.05, 0.06, 0.08), fog);
      return vec4<f32>(color, 1.0);
    }

    if (tMax.x < tMax.y && tMax.x < tMax.z) {
      voxel.x = voxel.x + step.x;
      tMax.x = tMax.x + tDelta.x;
      normal = vec3<f32>(-f32(step.x), 0.0, 0.0);
    } else if (tMax.y < tMax.z) {
      voxel.y = voxel.y + step.y;
      tMax.y = tMax.y + tDelta.y;
      normal = vec3<f32>(0.0, -f32(step.y), 0.0);
    } else {
      voxel.z = voxel.z + step.z;
      tMax.z = tMax.z + tDelta.z;
      normal = vec3<f32>(0.0, 0.0, -f32(step.z));
    }
  }

  return vec4<f32>(0.05, 0.06, 0.08, 1.0);
}
`,
});

const computePipeline = device.createComputePipeline({
  layout: "auto",
  compute: { module: computeShader, entryPoint: "simulate" },
});

const renderPipeline = device.createRenderPipeline({
  layout: "auto",
  vertex: { module: renderShader, entryPoint: "vsMain" },
  fragment: {
    module: renderShader,
    entryPoint: "fsMain",
    targets: [
      {
        format,
        blend: {
          color: {
            srcFactor: "src-alpha",
            dstFactor: "one-minus-src-alpha",
            operation: "add",
          },
          alpha: {
            srcFactor: "one",
            dstFactor: "one-minus-src-alpha",
            operation: "add",
          },
        },
      },
    ],
  },
  primitive: { topology: "triangle-list" },
});

let readBuffer = stateA;
let writeBuffer = stateB;

const computeBindGroup = () =>
  device.createBindGroup({
    layout: computePipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: readBuffer } },
      { binding: 1, resource: { buffer: writeBuffer } },
      { binding: 2, resource: { buffer: paramBuffer } },
      { binding: 3, resource: { buffer: countBuffer } },
    ],
  });

const renderBindGroup = () =>
  device.createBindGroup({
    layout: renderPipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: readBuffer } },
      { binding: 1, resource: { buffer: paramBuffer } },
    ],
  });

const ITEM_NONE = 0;
const ITEM_HAMMER = 1;
const ITEM_VACUUM = 2;
const ITEM_SAND = 3;

const hotbarSlots = 9;
const inventory = Array.from({ length: hotbarSlots }, () => ({ id: ITEM_NONE, count: 0 }));
inventory[0] = { id: ITEM_HAMMER, count: 0 };
inventory[1] = { id: ITEM_VACUUM, count: 0 };
let selectedSlot = 0;
let lastSandSlot = -1;
let collectPulse = 0;

const hotbarEls = Array.from(document.querySelectorAll(".slot"));
const heldItemEl = document.querySelector(".held-item");

const player = {
  position: [gridWidth * 0.5, 2, gridDepth * 0.2],
  velocity: [0, 0, 0],
  radius: 3.5,
  height: 16,
  eyeHeight: 14,
  onGround: false,
};

const camera = {
  fov: (60 * Math.PI) / 180,
  yaw: Math.PI,
  pitch: 0,
  speed: 18,
};

let lastTime = performance.now();
let pointerLocked = false;
const keyState = new Set();
const swingReach = 12;
const swingRadius = 3.5;
const vacuumTarget = {
  x: Math.floor(gridWidth * 0.8),
  y: 10,
  z: Math.floor(gridDepth * 0.8),
  radius: 2.5,
};
let frameCount = 0;
const mouseState = { left: false };
let countReadPending = false;
let pendingTool = TOOL_NONE;
let pendingSlot = 0;
let lastDebugCam = [0, 0, 0];
let lastDebugSwing = [0, 0, 0];

canvas.addEventListener("contextmenu", (event) => event.preventDefault());

document.addEventListener("pointerlockchange", () => {
  pointerLocked = document.pointerLockElement === canvas;
});

canvas.addEventListener("pointerdown", (event) => {
  if (!pointerLocked) {
    canvas.requestPointerLock();
    return;
  }
  if (event.button === 0) {
    mouseState.left = true;
  }
});

canvas.addEventListener("pointerup", (event) => {
  if (event.button === 0) {
    mouseState.left = false;
  }
});

canvas.addEventListener("pointermove", (event) => {
  if (!pointerLocked) {
    return;
  }
  camera.yaw -= event.movementX * 0.002;
  camera.pitch -= event.movementY * 0.002;
  camera.pitch = Math.max(-1.3, Math.min(1.3, camera.pitch));
});

document.addEventListener("keydown", (event) => {
  keyState.add(event.code);
  if (event.code.startsWith("Digit")) {
    const index = Number(event.code.slice(5)) - 1;
    if (index >= 0 && index <= 7) {
      selectedSlot = index;
      renderHotbar();
    }
  }
});

document.addEventListener("keyup", (event) => {
  keyState.delete(event.code);
});

function renderHotbar() {
  hotbarEls.forEach((slotEl, index) => {
    const slot = inventory[index];
    slotEl.classList.toggle("active", index === selectedSlot);
    slotEl.classList.toggle("collected", collectPulse > 0 && index === lastSandSlot);
    const countEl = slotEl.querySelector(".slot-count");
    countEl.textContent = slot.count > 0 ? String(slot.count) : "";
  });

  if (!heldItemEl) {
    return;
  }
  const selected = inventory[selectedSlot];
  if (selected.id === ITEM_VACUUM) {
    heldItemEl.style.background = "linear-gradient(135deg, #64d6ff, #0b4870)";
  } else if (selected.id === ITEM_HAMMER) {
    heldItemEl.style.background = "linear-gradient(135deg, #f6c26b, #c47a2b)";
  } else if (selected.id === ITEM_SAND) {
    heldItemEl.style.background = "linear-gradient(135deg, #f5d48e, #b8873a)";
  } else {
    heldItemEl.style.background = "linear-gradient(135deg, #2a2f35, #1b2026)";
  }
}

function addSandToInventory(amount) {
  let slotIndex = inventory.findIndex((slot) => slot.id === ITEM_SAND);
  if (slotIndex === -1) {
    for (let i = 1; i <= hotbarSlots; i += 1) {
      const idx = (selectedSlot + i) % hotbarSlots;
      if (inventory[idx].id === ITEM_NONE) {
        slotIndex = idx;
        break;
      }
    }
    if (slotIndex === -1) {
      return;
    }
    inventory[slotIndex] = { id: ITEM_SAND, count: 0 };
  }
  inventory[slotIndex].count += amount;
  lastSandSlot = slotIndex;
  collectPulse = 8;
  renderHotbar();
}

renderHotbar();


function currentTool() {
  if (!pointerLocked || !mouseState.left) {
    return TOOL_NONE;
  }
  const selected = inventory[selectedSlot];
  if (selected.id === ITEM_HAMMER) {
    return TOOL_HAMMER;
  }
  if (selected.id === ITEM_VACUUM) {
    return TOOL_VACUUM;
  }
  if (selected.id === ITEM_SAND && selected.count > 0) {
    return TOOL_PLACE;
  }
  return TOOL_NONE;
}

function normalize(vec) {
  const len = Math.hypot(vec[0], vec[1], vec[2]);
  return len > 0 ? [vec[0] / len, vec[1] / len, vec[2] / len] : [0, 0, 0];
}

function cross(a, b) {
  return [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];
}

function computeCameraBasis() {
  const cp = Math.cos(camera.pitch);
  const sp = Math.sin(camera.pitch);
  const cy = Math.cos(camera.yaw);
  const sy = Math.sin(camera.yaw);

  const forward = normalize([sy * cp, sp, cy * cp]);
  const right = normalize(cross(forward, [0, 1, 0]));
  const up = normalize(cross(right, forward));

  return { forward, right, up };
}

function updatePlayer(dt) {
  const { forward, right } = computeCameraBasis();
  const forwardFlat = normalize([forward[0], 0, forward[2]]);
  const rightFlat = normalize([right[0], 0, right[2]]);

  let moveX = 0;
  let moveZ = 0;
  if (keyState.has("KeyW")) moveZ += 1;
  if (keyState.has("KeyS")) moveZ -= 1;
  if (keyState.has("KeyA")) moveX -= 1;
  if (keyState.has("KeyD")) moveX += 1;

  const desired = normalize([
    rightFlat[0] * moveX + forwardFlat[0] * moveZ,
    0,
    rightFlat[2] * moveX + forwardFlat[2] * moveZ,
  ]);

  const targetSpeed = keyState.has("ShiftLeft") ? camera.speed * 1.8 : camera.speed;
  const accel = 18;

  player.velocity[0] += (desired[0] * targetSpeed - player.velocity[0]) * Math.min(1, accel * dt);
  player.velocity[2] += (desired[2] * targetSpeed - player.velocity[2]) * Math.min(1, accel * dt);

  const gravity = 42;
  player.velocity[1] -= gravity * dt;

  if (player.onGround && keyState.has("Space")) {
    player.velocity[1] = 18;
    player.onGround = false;
  }

  player.position[0] += player.velocity[0] * dt;
  player.position[1] += player.velocity[1] * dt;
  player.position[2] += player.velocity[2] * dt;

  const minY = 1;
  const maxY = gridHeight - player.height;
  if (player.position[1] < minY) {
    player.position[1] = minY;
    player.velocity[1] = 0;
    player.onGround = true;
  } else if (player.position[1] > maxY) {
    player.position[1] = maxY;
    player.velocity[1] = 0;
  } else {
    player.onGround = false;
  }

  const margin = player.radius;
  player.position[0] = Math.max(margin, Math.min(gridWidth - margin, player.position[0]));
  player.position[2] = Math.max(margin, Math.min(gridDepth - margin, player.position[2]));
}

function writeParams() {
  const basis = computeCameraBasis();
  const rect = canvas.getBoundingClientRect();
  const aspect = rect.width / rect.height;
  const tanHalf = Math.tan(camera.fov * 0.5);

  const camPos = new Float32Array([
    player.position[0],
    player.position[1] + player.eyeHeight,
    player.position[2],
    0,
  ]);

  const toolId = currentTool();
  const maxPlace = toolId === TOOL_PLACE ? inventory[selectedSlot].count : 0;
  const swingActive = toolId !== TOOL_NONE ? 1 : 0;
  const swingPos = [
    camPos[0] + basis.forward[0] * swingReach,
    camPos[1] + basis.forward[1] * swingReach,
    camPos[2] + basis.forward[2] * swingReach,
  ];

  const grid = new Uint32Array([gridWidth, gridHeight, gridDepth, frameCount]);
  const camDir = new Float32Array([basis.forward[0], basis.forward[1], basis.forward[2], 0]);
  const camRight = new Float32Array([basis.right[0], basis.right[1], basis.right[2], 0]);
  const camUp = new Float32Array([basis.up[0], basis.up[1], basis.up[2], 0]);
  const screen = new Float32Array([rect.width, rect.height, tanHalf, aspect]);
  const swing = new Float32Array([
    swingPos[0],
    swingPos[1],
    swingPos[2],
    swingActive ? swingRadius : 0,
  ]);
  const tool = new Uint32Array([toolId, maxPlace, 0, 0]);
  const vacuum = new Float32Array([vacuumTarget.x, vacuumTarget.y, vacuumTarget.z, vacuumTarget.radius]);

  lastDebugCam = [camPos[0], camPos[1], camPos[2]];
  lastDebugSwing = [swingPos[0], swingPos[1], swingPos[2]];


  const bytes = new ArrayBuffer(144);
  new Uint32Array(bytes, 0, 4).set(grid);
  new Float32Array(bytes, 16, 4).set(camPos);
  new Float32Array(bytes, 32, 4).set(camDir);
  new Float32Array(bytes, 48, 4).set(camRight);
  new Float32Array(bytes, 64, 4).set(camUp);
  new Float32Array(bytes, 80, 4).set(screen);
  new Float32Array(bytes, 96, 4).set(swing);
  new Uint32Array(bytes, 112, 4).set(tool);
  new Float32Array(bytes, 128, 4).set(vacuum);
  device.queue.writeBuffer(paramBuffer, 0, bytes);
}

function frameLoop(now) {
  const dt = Math.min(0.05, (now - lastTime) / 1000);
  lastTime = now;
  frameCount += 1;
  if (collectPulse > 0) {
    collectPulse -= 1;
  }

  if (pointerLocked) {
    updatePlayer(dt);
  }

  const toolId = currentTool();
  const wantsCount = toolId === TOOL_VACUUM || toolId === TOOL_PLACE;
  document.body.classList.toggle("vacuuming", toolId === TOOL_VACUUM);
  if (wantsCount) {
    device.queue.writeBuffer(countBuffer, 0, new Uint32Array(12));
  }
  writeParams();

  const encoder = device.createCommandEncoder();

  {
    const pass = encoder.beginComputePass();
    pass.setPipeline(computePipeline);
    pass.setBindGroup(0, computeBindGroup());
    pass.dispatchWorkgroups(
      Math.ceil(gridWidth / 4),
      Math.ceil(gridHeight / 4),
      Math.ceil(gridDepth / 4)
    );
    pass.end();
  }

  if (wantsCount && !countReadPending) {
    encoder.copyBufferToBuffer(countBuffer, 0, countReadBuffer, 0, 48);
  }

  {
    const renderPass = encoder.beginRenderPass({
      colorAttachments: [
        {
          view: context.getCurrentTexture().createView(),
          loadOp: "clear",
          storeOp: "store",
          clearValue: { r: 0.04, g: 0.05, b: 0.06, a: 1 },
        },
      ],
    });
    renderPass.setPipeline(renderPipeline);
    renderPass.setBindGroup(0, renderBindGroup());
    renderPass.draw(3);
    renderPass.end();
  }

  device.queue.submit([encoder.finish()]);

  if (wantsCount && !countReadPending) {
    countReadPending = true;
    pendingTool = toolId;
    pendingSlot = selectedSlot;
    countReadBuffer.mapAsync(GPUMapMode.READ).then(() => {
      const data = new Uint32Array(countReadBuffer.getMappedRange());
      const vacuumed = data[0];
      const placed = data[1];
      const tagged = data[2];
      const moved = data[3];
      const seen = data[4];
      const deleted = data[5];
      countReadBuffer.unmap();
      countReadPending = false;

      if (pendingTool === TOOL_VACUUM && vacuumed > 0) {
        addSandToInventory(vacuumed);
      }
      if (pendingTool === TOOL_PLACE && placed > 0) {
        const slot = inventory[pendingSlot];
        if (slot.id === ITEM_SAND) {
          slot.count = Math.max(0, slot.count - placed);
          if (slot.count === 0) {
            slot.id = ITEM_NONE;
          }
          renderHotbar();
        }
      }
      if (pendingTool === TOOL_VACUUM && frameCount % 10 === 0) {
        const sandSlot = lastSandSlot >= 0 ? lastSandSlot + 1 : 0;
        const sandCount = lastSandSlot >= 0 ? inventory[lastSandSlot].count : 0;
        console.log(
          `[vacuum] tagged=${tagged} moved=${moved} seen=${seen} deleted=${deleted} collected=${vacuumed} sandSlot=${sandSlot} sandCount=${sandCount}`
        );
        console.log(
          `[vacuum] cam=(${lastDebugCam[0].toFixed(2)},${lastDebugCam[1].toFixed(2)},${lastDebugCam[2].toFixed(2)}) swing=(${lastDebugSwing[0].toFixed(2)},${lastDebugSwing[1].toFixed(2)},${lastDebugSwing[2].toFixed(2)})`
        );
      }
    });
  }

  const temp = readBuffer;
  readBuffer = writeBuffer;
  writeBuffer = temp;

  requestAnimationFrame(frameLoop);
}

requestAnimationFrame(frameLoop);
