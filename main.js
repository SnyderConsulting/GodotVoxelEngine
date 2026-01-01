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

const TOOL_NONE = 0;
const TOOL_ADD = 1;
const TOOL_ERASE = 2;

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

const cubeSize = 28;
const cubeStartX = Math.floor(gridWidth / 2 - cubeSize / 2);
const cubeStartY = 30;
const cubeStartZ = Math.floor(gridDepth / 2 - cubeSize / 2);

for (let z = 0; z < cubeSize; z += 1) {
  for (let y = 0; y < cubeSize; y += 1) {
    for (let x = 0; x < cubeSize; x += 1) {
      const ix = cubeStartX + x;
      const iy = cubeStartY + y;
      const iz = cubeStartZ + z;
      initState[idx(ix, iy, iz)] = MAT_SAND;
    }
  }
}

device.queue.writeBuffer(stateA, 0, initState);
device.queue.writeBuffer(stateB, 0, initState);

const paramBuffer = device.createBuffer({
  size: 128,
  usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
});

const brushBuffer = device.createBuffer({
  size: 32,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
});

device.queue.writeBuffer(brushBuffer, 0, new Float32Array([0, 0, 0, 6]));

device.queue.writeBuffer(brushBuffer, 16, new Uint32Array([0, 0, 0, 0]));

const pickShader = device.createShaderModule({
  code: `
struct Params {
  grid : vec4<u32>,
  camPos : vec4<f32>,
  camDir : vec4<f32>,
  camRight : vec4<f32>,
  camUp : vec4<f32>,
  screen : vec4<f32>,
  mouse : vec4<f32>,
  brush : vec4<f32>,
};

struct BrushState {
  posRadius : vec4<f32>,
  tool : u32,
  enabled : u32,
  pad : vec2<u32>,
};

@group(0) @binding(0) var<storage, read> stateIn : array<u32>;
@group(0) @binding(1) var<storage, read_write> brushOut : BrushState;
@group(0) @binding(2) var<uniform> params : Params;

const MAT_EMPTY : u32 = 0u;
const MAT_MASK : u32 = 3u;

fn idx(x : i32, y : i32, z : i32) -> u32 {
  return u32(x) + u32(y) * params.grid.x + u32(z) * params.grid.x * params.grid.y;
}

fn inBounds(x : i32, y : i32, z : i32) -> bool {
  return x >= 0 && y >= 0 && z >= 0 && x < i32(params.grid.x) && y < i32(params.grid.y) && z < i32(params.grid.z);
}

fn getCell(x : i32, y : i32, z : i32) -> u32 {
  if (!inBounds(x, y, z)) {
    return MAT_EMPTY;
  }
  return stateIn[idx(x, y, z)];
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

@compute @workgroup_size(1)
fn pick() {
  if (params.mouse.z < 0.5) {
    brushOut.enabled = 0u;
    return;
  }

  let px = params.mouse.x * params.screen.w;
  let py = params.mouse.y * params.screen.z;
  let rayDir = normalize(params.camDir.xyz + params.camRight.xyz * px + params.camUp.xyz * py);
  let rayOrigin = params.camPos.xyz;

  let boundsMin = vec3<f32>(0.0, 0.0, 0.0);
  let boundsMax = vec3<f32>(f32(params.grid.x), f32(params.grid.y), f32(params.grid.z));
  let hit = intersectAABB(rayOrigin, rayDir, boundsMin, boundsMax);
  if (hit.y < max(hit.x, 0.0)) {
    brushOut.enabled = 0u;
    return;
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

  var tNow = t;
  for (var i = 0; i < 512; i = i + 1) {
    if (!inBounds(voxel.x, voxel.y, voxel.z)) {
      break;
    }
    if (tNow >= params.brush.y) {
      let cell = getCell(voxel.x, voxel.y, voxel.z);
      if ((cell & MAT_MASK) != MAT_EMPTY) {
        brushOut.posRadius = vec4<f32>(vec3<f32>(f32(voxel.x) + 0.5, f32(voxel.y) + 0.5, f32(voxel.z) + 0.5), params.brush.x);
        brushOut.tool = u32(params.mouse.w + 0.5);
        brushOut.enabled = 1u;
        return;
      }
    }

    if (tMax.x < tMax.y && tMax.x < tMax.z) {
      voxel.x = voxel.x + step.x;
      tNow = tMax.x;
      tMax.x = tMax.x + tDelta.x;
    } else if (tMax.y < tMax.z) {
      voxel.y = voxel.y + step.y;
      tNow = tMax.y;
      tMax.y = tMax.y + tDelta.y;
    } else {
      voxel.z = voxel.z + step.z;
      tNow = tMax.z;
      tMax.z = tMax.z + tDelta.z;
    }
  }

  brushOut.enabled = 0u;
}
`,
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
  mouse : vec4<f32>,
  brush : vec4<f32>,
};

struct BrushState {
  posRadius : vec4<f32>,
  tool : u32,
  enabled : u32,
  pad : vec2<u32>,
};

@group(0) @binding(0) var<storage, read> stateIn : array<u32>;
@group(0) @binding(1) var<storage, read_write> stateOut : array<u32>;
@group(0) @binding(2) var<uniform> params : Params;
@group(0) @binding(3) var<storage, read> brush : BrushState;

const MAT_EMPTY : u32 = 0u;
const MAT_SAND : u32 = 1u;
const MAT_WALL : u32 = 2u;
const MAT_MASK : u32 = 3u;
const ACTIVE_MASK : u32 = 4u;

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

fn brushInside(x : i32, y : i32, z : i32) -> bool {
  if (brush.enabled == 0u) {
    return false;
  }
  let dx = f32(x) + 0.5 - brush.posRadius.x;
  let dy = f32(y) + 0.5 - brush.posRadius.y;
  let dz = f32(z) + 0.5 - brush.posRadius.z;
  return dx * dx + dy * dy + dz * dz <= brush.posRadius.w * brush.posRadius.w;
}

fn activeFor(x : i32, y : i32, z : i32, cell : u32) -> bool {
  if ((cell & MAT_MASK) != MAT_SAND) {
    return false;
  }
  if ((cell & ACTIVE_MASK) != 0u) {
    return true;
  }
  let below = getCell(x, y - 1, z);
  return (below & MAT_MASK) == MAT_EMPTY;
}

fn moveDir(x : i32, y : i32, z : i32, cell : u32) -> vec3<i32> {
  if ((cell & MAT_MASK) != MAT_SAND) {
    return vec3<i32>(0, 0, 0);
  }
  if (!activeFor(x, y, z, cell)) {
    return vec3<i32>(0, 0, 0);
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

@compute @workgroup_size(4, 4, 4)
fn simulate(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x >= params.grid.x || gid.y >= params.grid.y || gid.z >= params.grid.z) {
    return;
  }

  let x = i32(gid.x);
  let y = i32(gid.y);
  let z = i32(gid.z);
  let index = idx(x, y, z);
  let cell = getCell(x, y, z);
  let mat = cell & MAT_MASK;

  if (mat == MAT_WALL) {
    stateOut[index] = MAT_WALL;
    return;
  }

  if (brush.tool == 1u && brushInside(x, y, z)) {
    stateOut[index] = MAT_SAND | ACTIVE_MASK;
    return;
  }

  if (brush.tool == 2u && brushInside(x, y, z)) {
    stateOut[index] = MAT_EMPTY;
    return;
  }

  var incomingCount = 0u;
  var incoming = false;
  let seed = hash(u32(x), u32(y), u32(z), params.grid.w);

  let fromAbove = wantsMove(x, y + 1, z, vec3<i32>(0, -1, 0));
  if (fromAbove) {
    incomingCount = incomingCount + 1u;
    if ((seed % incomingCount) == 0u) {
      incoming = true;
    }
  }

  let fromLeft = wantsMove(x - 1, y + 1, z, vec3<i32>(1, -1, 0));
  if (fromLeft) {
    incomingCount = incomingCount + 1u;
    if ((seed % incomingCount) == 0u) {
      incoming = true;
    }
  }

  let fromRight = wantsMove(x + 1, y + 1, z, vec3<i32>(-1, -1, 0));
  if (fromRight) {
    incomingCount = incomingCount + 1u;
    if ((seed % incomingCount) == 0u) {
      incoming = true;
    }
  }

  let fromFront = wantsMove(x, y + 1, z - 1, vec3<i32>(0, -1, 1));
  if (fromFront) {
    incomingCount = incomingCount + 1u;
    if ((seed % incomingCount) == 0u) {
      incoming = true;
    }
  }

  let fromBack = wantsMove(x, y + 1, z + 1, vec3<i32>(0, -1, -1));
  if (fromBack) {
    incomingCount = incomingCount + 1u;
    if ((seed % incomingCount) == 0u) {
      incoming = true;
    }
  }

  if (incoming) {
    stateOut[index] = MAT_SAND | ACTIVE_MASK;
    return;
  }

  if (mat == MAT_SAND) {
    let dir = moveDir(x, y, z, cell);
    if (all(dir == vec3<i32>(0, 0, 0))) {
      let isActive = activeFor(x, y, z, cell);
      stateOut[index] = MAT_SAND | select(0u, ACTIVE_MASK, isActive);
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
  mouse : vec4<f32>,
  brush : vec4<f32>,
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

@fragment
fn fsMain(input : VsOut) -> @location(0) vec4<f32> {
  let uv = clamp(input.uv, vec2<f32>(0.0), vec2<f32>(1.0));
  let px = (uv.x * 2.0 - 1.0) * params.screen.w;
  let py = (1.0 - uv.y * 2.0) * params.screen.z;
  let rayDir = normalize(params.camDir.xyz + params.camRight.xyz * px + params.camUp.xyz * py);
  let rayOrigin = params.camPos.xyz;

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
      t = tMax.x;
      tMax.x = tMax.x + tDelta.x;
      normal = vec3<f32>(-f32(step.x), 0.0, 0.0);
    } else if (tMax.y < tMax.z) {
      voxel.y = voxel.y + step.y;
      t = tMax.y;
      tMax.y = tMax.y + tDelta.y;
      normal = vec3<f32>(0.0, -f32(step.y), 0.0);
    } else {
      voxel.z = voxel.z + step.z;
      t = tMax.z;
      tMax.z = tMax.z + tDelta.z;
      normal = vec3<f32>(0.0, 0.0, -f32(step.z));
    }
  }

  return vec4<f32>(0.05, 0.06, 0.08, 1.0);
}
`,
});

const pickPipeline = device.createComputePipeline({
  layout: "auto",
  compute: { module: pickShader, entryPoint: "pick" },
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
    targets: [{ format }],
  },
  primitive: { topology: "triangle-list" },
});

let readBuffer = stateA;
let writeBuffer = stateB;

const pickBindGroup = () =>
  device.createBindGroup({
    layout: pickPipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: readBuffer } },
      { binding: 1, resource: { buffer: brushBuffer } },
      { binding: 2, resource: { buffer: paramBuffer } },
    ],
  });

const computeBindGroup = () =>
  device.createBindGroup({
    layout: computePipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: readBuffer } },
      { binding: 1, resource: { buffer: writeBuffer } },
      { binding: 2, resource: { buffer: paramBuffer } },
      { binding: 3, resource: { buffer: brushBuffer } },
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

let lastTime = performance.now();

const camera = {
  fov: (60 * Math.PI) / 180,
  position: [gridWidth * 0.5, gridHeight * 0.6, gridDepth * 1.8],
  yaw: Math.PI,
  pitch: -0.25,
  speed: 18,
};

let pointerLocked = false;
const keyState = new Set();
const mouseState = { left: false, right: false };
let mouseNdc = { x: 0, y: 0 };

canvas.addEventListener("contextmenu", (event) => event.preventDefault());

document.addEventListener("pointerlockchange", () => {
  pointerLocked = document.pointerLockElement === canvas;
});

canvas.addEventListener("pointerdown", (event) => {
  if (!pointerLocked) {
    canvas.requestPointerLock();
  }
  if (event.button === 0) {
    mouseState.left = true;
  }
  if (event.button === 2) {
    mouseState.right = true;
  }
  if (!pointerLocked) {
    updateMouseNdc(event);
  }
});

canvas.addEventListener("pointerup", (event) => {
  if (event.button === 0) {
    mouseState.left = false;
  }
  if (event.button === 2) {
    mouseState.right = false;
  }
});

canvas.addEventListener("pointermove", (event) => {
  if (pointerLocked) {
    camera.yaw -= event.movementX * 0.002;
    camera.pitch -= event.movementY * 0.002;
    camera.pitch = Math.max(-1.3, Math.min(1.3, camera.pitch));
    return;
  }
  updateMouseNdc(event);
});

document.addEventListener("keydown", (event) => {
  keyState.add(event.code);
});

document.addEventListener("keyup", (event) => {
  keyState.delete(event.code);
});

function updateMouseNdc(event) {
  const rect = canvas.getBoundingClientRect();
  const px = (event.clientX - rect.left) / rect.width;
  const py = (event.clientY - rect.top) / rect.height;
  mouseNdc = { x: px * 2 - 1, y: 1 - py * 2 };
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

function updateCamera(dt) {
  const { forward, right } = computeCameraBasis();
  let moveX = 0;
  let moveZ = 0;
  let moveY = 0;

  if (keyState.has("KeyW")) moveZ += 1;
  if (keyState.has("KeyS")) moveZ -= 1;
  if (keyState.has("KeyA")) moveX -= 1;
  if (keyState.has("KeyD")) moveX += 1;
  if (keyState.has("Space")) moveY += 1;
  if (keyState.has("ShiftLeft")) moveY -= 1;

  const speed = keyState.has("ShiftRight") ? camera.speed * 2.5 : camera.speed;
  const scale = speed * dt;

  camera.position[0] += (right[0] * moveX + forward[0] * moveZ) * scale;
  camera.position[1] += (right[1] * moveX + forward[1] * moveZ + moveY) * scale;
  camera.position[2] += (right[2] * moveX + forward[2] * moveZ) * scale;

  camera.position[0] = Math.max(2, Math.min(gridWidth - 2, camera.position[0]));
  camera.position[1] = Math.max(2, Math.min(gridHeight - 2, camera.position[1]));
  camera.position[2] = Math.max(2, Math.min(gridDepth - 2, camera.position[2]));
}

function currentTool() {
  if (mouseState.right) return TOOL_ERASE;
  if (mouseState.left) return TOOL_ADD;
  return TOOL_NONE;
}

function writeParams() {
  const basis = computeCameraBasis();
  const rect = canvas.getBoundingClientRect();
  const aspect = rect.width / rect.height;
  const tanHalf = Math.tan(camera.fov * 0.5);

  const tool = currentTool();
  const mouse = new Float32Array([
    pointerLocked ? 0 : mouseNdc.x,
    pointerLocked ? 0 : mouseNdc.y,
    tool === TOOL_NONE ? 0 : 1,
    tool,
  ]);

  const grid = new Uint32Array([gridWidth, gridHeight, gridDepth, 0]);
  const camPos = new Float32Array([camera.position[0], camera.position[1], camera.position[2], 0]);
  const camDir = new Float32Array([basis.forward[0], basis.forward[1], basis.forward[2], 0]);
  const camRight = new Float32Array([basis.right[0], basis.right[1], basis.right[2], 0]);
  const camUp = new Float32Array([basis.up[0], basis.up[1], basis.up[2], 0]);
  const screen = new Float32Array([rect.width, rect.height, tanHalf, aspect]);
  const brush = new Float32Array([6, 8, 0, 0]);

  const bytes = new ArrayBuffer(128);
  new Uint32Array(bytes, 0, 4).set(grid);
  new Float32Array(bytes, 16, 4).set(camPos);
  new Float32Array(bytes, 32, 4).set(camDir);
  new Float32Array(bytes, 48, 4).set(camRight);
  new Float32Array(bytes, 64, 4).set(camUp);
  new Float32Array(bytes, 80, 4).set(screen);
  new Float32Array(bytes, 96, 4).set(mouse);
  new Float32Array(bytes, 112, 4).set(brush);
  device.queue.writeBuffer(paramBuffer, 0, bytes);
}

function frameLoop(now) {
  const dt = Math.min(0.05, (now - lastTime) / 1000);
  lastTime = now;

  updateCamera(dt);
  writeParams();

  const encoder = device.createCommandEncoder();

  {
    const pass = encoder.beginComputePass();
    pass.setPipeline(pickPipeline);
    pass.setBindGroup(0, pickBindGroup());
    pass.dispatchWorkgroups(1);
    pass.end();
  }

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

  const temp = readBuffer;
  readBuffer = writeBuffer;
  writeBuffer = temp;

  requestAnimationFrame(frameLoop);
}

requestAnimationFrame(frameLoop);
