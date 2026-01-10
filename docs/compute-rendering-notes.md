# Compute Rendering Notes

> Current state: the active compute pipelines now live in the engine module (`godot/engine-src/modules/voxels`). The project-side `.glsl` files are kept for reference/experimentation; follow these notes if authoring new shaders or validating legacy copies.

## Summary
- Compute GLSL files are not auto-imported as RDShaderFile resources unless the shader file importer runs. In this project, loading a `.glsl` directly failed and broke the script.
- Workaround: load the GLSL source with `FileAccess.get_file_as_string`, remove the `#[compute]` hint, then compile via `RDShaderSource` and `RenderingDevice.shader_compile_spirv_from_source()`.
- Use the global RenderingDevice (`RenderingServer.get_rendering_device()`) when you need textures sampled by the main render pipeline. A local RenderingDevice keeps resources isolated.
- To guarantee a quad uses a shader, set `material_override` (and optionally `set_surface_override_material(0, ...)`) on the MeshInstance3D.

## Minimal Working Flow
1. Create a `QuadMesh` in front of the camera.
2. Assign a display shader that samples a `Texture2DRD` bound to a storage image.
3. Compile compute shader source via `RDShaderSource` and create a compute pipeline.
4. Create a storage image texture with `TEXTURE_USAGE_STORAGE_BIT | TEXTURE_USAGE_SAMPLING_BIT`.
5. Dispatch the compute shader each frame, then sample the texture in the display shader.

## Debugging Checklist
- If you see solid gray: verify the script loaded and the quad has a material override.
- If you see magenta: the display shader is active; compute output may be missing.
- If GLSL import fails: remove `#[compute]` and compile using `RDShaderSource`.
- Use automation screenshots to confirm render output.
