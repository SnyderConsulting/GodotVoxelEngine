extends RefCounted
class_name WorldGenCaves

# Procedural cave worldgen for the single-chunk prototype.
# Outputs `set_voxel_entries`-compatible dictionaries: {"pos": Vector3(x,y,z), "material": int}.

func _is_bcc_cell(x: int, y: int, z: int) -> bool:
    return ((x & 1) == (y & 1)) and ((y & 1) == (z & 1))

func _idx3(x: int, y: int, z: int, n: int) -> int:
    return x + y * n + z * n * n

func _carve_sphere(mask: PackedByteArray, n: int, center: Vector3, radius: float, boundary_wall: int) -> void:
    var r := maxf(0.5, radius)
    var r2 := r * r
    var min_x := clampi(int(floor(center.x - r)), boundary_wall, n - 1 - boundary_wall)
    var max_x := clampi(int(ceil(center.x + r)), boundary_wall, n - 1 - boundary_wall)
    var min_y := clampi(int(floor(center.y - r)), boundary_wall, n - 1 - boundary_wall)
    var max_y := clampi(int(ceil(center.y + r)), boundary_wall, n - 1 - boundary_wall)
    var min_z := clampi(int(floor(center.z - r)), boundary_wall, n - 1 - boundary_wall)
    var max_z := clampi(int(ceil(center.z + r)), boundary_wall, n - 1 - boundary_wall)
    for z in range(min_z, max_z + 1):
        for y in range(min_y, max_y + 1):
            for x in range(min_x, max_x + 1):
                if !_is_bcc_cell(x, y, z):
                    continue
                var d2 := (Vector3(float(x), float(y), float(z)) - center).length_squared()
                if d2 > r2:
                    continue
                mask[_idx3(x, y, z, n)] = 1

func generate_entries(grid_extent: int, seed: int, params: Dictionary) -> Array:
    var n: int = maxi(8, int(grid_extent))
    var rng := RandomNumberGenerator.new()
    rng.seed = int(seed)

    var base_y := int(params.get("base_y", 4))
    var terrain_height := int(params.get("terrain_height", 22))
    var height_amplitude := float(params.get("height_amplitude", 6.0))
    var height_frequency := float(params.get("height_frequency", 0.03))

    var grass_id := int(params.get("grass_id", 12))
    var dirt_id := int(params.get("dirt_id", 13))
    var stone_id := int(params.get("stone_id", 4))
    var ore_id := int(params.get("ore_id", 14))
    var water_id := int(params.get("water_id", 2))

    var dirt_depth := int(params.get("dirt_depth", 5))
    var boundary_wall := clampi(int(params.get("boundary_wall", 2)), 0, 8)

    var caves_enabled := bool(params.get("caves_enabled", true))
    var cave_frequency := float(params.get("cave_frequency", 0.09))
    var cave_threshold_shallow := float(params.get("cave_threshold_shallow", 0.68))
    var cave_threshold_deep := float(params.get("cave_threshold_deep", 0.53))
    var cave_surface_buffer := int(params.get("cave_surface_buffer", 6))
    var cave_min_y := int(params.get("cave_min_y", 4))

    var worm_count := int(params.get("worm_count", 7))
    var worm_length := int(params.get("worm_length", 120))
    var worm_radius := float(params.get("worm_radius", 2.3))
    var worm_step := float(params.get("worm_step", 1.4))

    var water_source_count := int(params.get("water_source_count", 8))
    var water_source_radius := float(params.get("water_source_radius", 2.0))
    var water_max_y := int(params.get("water_max_y", base_y + int(round(float(terrain_height) * 0.55))))

    var ore_frequency := float(params.get("ore_frequency", 0.12))
    var ore_threshold := float(params.get("ore_threshold", 0.78))
    var ore_min_y := int(params.get("ore_min_y", 4))

    # Heightmap noise
    var height_noise := FastNoiseLite.new()
    height_noise.seed = seed
    height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    height_noise.frequency = height_frequency
    height_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    height_noise.fractal_octaves = 4
    height_noise.fractal_gain = 0.5
    height_noise.fractal_lacunarity = 2.0

    # Cave density noise
    var cave_noise := FastNoiseLite.new()
    cave_noise.seed = seed + 1337
    cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    cave_noise.frequency = cave_frequency
    cave_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    cave_noise.fractal_octaves = 3
    cave_noise.fractal_gain = 0.55
    cave_noise.fractal_lacunarity = 2.0

    # Ore cluster noise
    var ore_noise := FastNoiseLite.new()
    ore_noise.seed = seed + 424242
    ore_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    ore_noise.frequency = ore_frequency
    ore_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    ore_noise.fractal_octaves = 2
    ore_noise.fractal_gain = 0.6
    ore_noise.fractal_lacunarity = 2.0

    var surface_y := PackedInt32Array()
    surface_y.resize(n * n)
    for z in range(n):
        for x in range(n):
            var hn := height_noise.get_noise_2d(float(x), float(z)) # [-1,1]
            var y_top := base_y + terrain_height + int(round(hn * height_amplitude))
            y_top = clampi(y_top, 4, n - 6)
            surface_y[x + z * n] = y_top

    # Carve mask: set bits where tunnels exist (worms). Caves also use noise at generation time.
    var carve := PackedByteArray()
    carve.resize(n * n * n)
    carve.fill(0)

    var max_spawn_tries := 32
    for wi in range(maxi(0, worm_count)):
        for attempt in range(max_spawn_tries):
            var sx := rng.randi_range(boundary_wall + 2, n - 3 - boundary_wall)
            var sz := rng.randi_range(boundary_wall + 2, n - 3 - boundary_wall)
            var surf := int(surface_y[sx + sz * n])
            var ymax := maxi(boundary_wall + 2, surf - 10)
            if ymax <= boundary_wall + 2:
                continue
            var sy := rng.randi_range(boundary_wall + 2, ymax)
            var pos := Vector3(float(sx), float(sy), float(sz))
            var dir := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.2, 0.2), rng.randf_range(-1.0, 1.0))
            if dir.length() < 0.2:
                dir = Vector3(1.0, 0.0, 0.0)
            dir = dir.normalized()
            for si in range(maxi(0, worm_length)):
                _carve_sphere(carve, n, pos, worm_radius + rng.randf_range(-0.25, 0.25), boundary_wall)
                dir = (dir + Vector3(rng.randf_range(-0.35, 0.35), rng.randf_range(-0.12, 0.12), rng.randf_range(-0.35, 0.35))).normalized()
                if dir.length() < 0.2:
                    dir = Vector3(1.0, 0.0, 0.0)
                pos += dir * worm_step
                pos.x = clampf(pos.x, float(boundary_wall + 2), float(n - 3 - boundary_wall))
                pos.y = clampf(pos.y, float(boundary_wall + 2), float(n - 3 - boundary_wall))
                pos.z = clampf(pos.z, float(boundary_wall + 2), float(n - 3 - boundary_wall))
            break

    # Water sources are just small blobs placed in caverns/tunnels; water will settle via sim.
    var water_sources: Array = []
    for _i in range(maxi(0, water_source_count)):
        for attempt in range(max_spawn_tries):
            var wx := rng.randi_range(boundary_wall + 2, n - 3 - boundary_wall)
            var wz := rng.randi_range(boundary_wall + 2, n - 3 - boundary_wall)
            var surf := int(surface_y[wx + wz * n])
            var wy_max := mini(mini(water_max_y, surf - 8), n - 4 - boundary_wall)
            if wy_max <= boundary_wall + 2:
                continue
            var wy := rng.randi_range(boundary_wall + 2, wy_max)
            var idx := _idx3(wx, wy, wz, n)
            var likely_cave := carve[idx] != 0
            if !likely_cave and caves_enabled:
                var cv := cave_noise.get_noise_3d(float(wx), float(wy), float(wz)) * 0.5 + 0.5
                likely_cave = cv > 0.65
            if !likely_cave:
                continue
            water_sources.append({"pos": Vector3(float(wx), float(wy), float(wz)), "r": water_source_radius})
            break

    var entries: Array = []
    entries.resize(0)

    for z in range(n):
        for x in range(n):
            var surf := int(surface_y[x + z * n])
            for y in range(0, surf + 1):
                if !_is_bcc_cell(x, y, z):
                    continue
                var mat := stone_id
                if y >= surf:
                    mat = grass_id
                elif y >= surf - dirt_depth:
                    mat = dirt_id

                # Keep the outer walls mostly solid so caves don't open to the void in the single-chunk prototype.
                var in_bounds_for_carve: bool = (
                    x >= boundary_wall and x < n - boundary_wall
                    and y >= boundary_wall and y < n - boundary_wall
                    and z >= boundary_wall and z < n - boundary_wall
                )

                var carved := false
                if caves_enabled and in_bounds_for_carve and y <= surf - cave_surface_buffer and y >= cave_min_y:
                    var idx := _idx3(x, y, z, n)
                    if carve[idx] != 0:
                        carved = true
                    else:
                        var cv := cave_noise.get_noise_3d(float(x), float(y) * 1.05, float(z)) * 0.5 + 0.5
                        var t := 0.0
                        var y0 := float(cave_min_y)
                        var y1 := float(maxi(cave_min_y + 1, surf - cave_surface_buffer))
                        if y1 > y0:
                            t = clamp((float(y) - y0) / (y1 - y0), 0.0, 1.0)
                        var thr := lerpf(cave_threshold_deep, cave_threshold_shallow, t)
                        if cv > thr:
                            carved = true

                if carved:
                    var p := Vector3(float(x), float(y), float(z))
                    var want_water := false
                    for src in water_sources:
                        var sp: Vector3 = src.get("pos", Vector3.ZERO)
                        var r: float = float(src.get("r", 0.0))
                        if (p - sp).length_squared() <= r * r:
                            want_water = true
                            break
                    if want_water:
                        entries.append({"pos": Vector3(x, y, z), "material": water_id})
                    continue

                if mat == stone_id and y >= ore_min_y and in_bounds_for_carve:
                    var ov := ore_noise.get_noise_3d(float(x), float(y), float(z)) * 0.5 + 0.5
                    if ov > ore_threshold:
                        mat = ore_id

                entries.append({"pos": Vector3(x, y, z), "material": mat})

    return entries
