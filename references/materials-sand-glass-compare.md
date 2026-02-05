# Sand + Glass: Merged Field Comparison (with linked refs)

## Sand

| Field | GodotVoxelEngine | Sandboxels | The Powder Toy |
|---|---|---|---|
| `material_id` | 1 |  |  |
| `Identifier` |  |  | "DEFAULT_PT_SAND" |
| `Name` |  |  | "SAND" |
| `Description` |  |  | "Sand, Heavy particles. Melts into glass." |
| `behavior` |  | behaviors.POWDER |  |
| `state` |  | "solid" |  |
| `density` |  | 1602 } |  |
| `tempHigh` |  | 1700 |  |
| `stateHigh` |  | "molten_glass" |  |
| `reactions` |  | { 		"water":{elem1:"wet_sand",elem2:null}, 		"salt_water"... |  |
| `category` |  | "land" |  |
| `color` |  | "#e6d577" |  |
| `Weight` |  |  | 90 |
| `Gravity` |  |  | 0.3f |
| `Falldown` |  |  | 1 |
| `Advection` |  |  | 0.4f |
| `AirDrag` |  |  | 0.04f * CFDS |
| `AirLoss` |  |  | 0.94f |
| `Loss` |  |  | 0.95f |
| `Collision` |  |  | -0.1f |
| `Diffusion` |  |  | 0.00f |
| `HotAir` |  |  | 0.000f	* CFDS |
| `HeatConduct` |  |  | 150 |
| `Properties` |  |  | TYPE_PART |
| `HighTemperature` |  |  | 1973.0f |
| `HighTemperatureTransition` |  |  | PT_LAVA |
| `Colour` |  |  | 0xFFD090_rgb |
| `Enabled` |  |  | 1 |
| `Explosive` |  |  | 0 |
| `Flammable` |  |  | 0 |
| `Hardness` |  |  | 1 |
| `HighPressure` |  |  | IPH |
| `HighPressureTransition` |  |  | NT |
| `LowPressure` |  |  | IPL |
| `LowPressureTransition` |  |  | NT |
| `LowTemperature` |  |  | ITL |
| `LowTemperatureTransition` |  |  | NT |
| `Meltable` |  |  | 5 |
| `MenuSection` |  |  | SC_POWDERS |
| `MenuVisible` |  |  | 1 |
| `render_behavior` | palette color (sand) |  |  |
| `sim_behavior` | CA fall via compute_sim.glsl |  |  |

## Glass

| Field | GodotVoxelEngine | Sandboxels | The Powder Toy |
|---|---|---|---|
| `material_id` | 8 |  |  |
| `Identifier` |  |  | "DEFAULT_PT_GLAS" |
| `Name` |  |  | "GLAS" |
| `Description` |  |  | "Glass. Meltable. Shatters under pressure, and refracts p... |
| `behavior` |  | behaviors.WALL |  |
| `renderer` |  | renderPresets.BORDER |  |
| `colorPattern` |  | textures.GLASS |  |
| `state` |  | "solid" |  |
| `density` |  | 2500 |  |
| `tempHigh` |  | 1500 |  |
| `reactions` |  | { 		"radiation": { elem1:"rad_glass", chance:0.33 }, 		"r... |  |
| `category` |  | "solids" |  |
| `color` |  | ["#5e807d" |  |
| `breakInto` |  | "glass_shard" |  |
| `Weight` |  |  | 100 |
| `Gravity` |  |  | 0.0f |
| `Falldown` |  |  | 0 |
| `Advection` |  |  | 0.0f |
| `AirDrag` |  |  | 0.00f * CFDS |
| `AirLoss` |  |  | 0.90f |
| `Loss` |  |  | 0.00f |
| `Collision` |  |  | 0.0f |
| `Diffusion` |  |  | 0.00f |
| `HotAir` |  |  | 0.000f	* CFDS |
| `HeatConduct` |  |  | 150 |
| `Properties` |  |  | TYPE_SOLID | PROP_NEUTPASS | PROP_PHOTPASS | PROP_HOT_GLO... |
| `HighTemperature` |  |  | 1973.0f |
| `HighTemperatureTransition` |  |  | PT_LAVA |
| `Colour` |  |  | 0x404040_rgb |
| `Create` |  |  | &create |
| `Enabled` |  |  | 1 |
| `Explosive` |  |  | 0 |
| `Flammable` |  |  | 0 |
| `Hardness` |  |  | 0 |
| `HighPressure` |  |  | IPH |
| `HighPressureTransition` |  |  | NT |
| `LowPressure` |  |  | IPL |
| `LowPressureTransition` |  |  | NT |
| `LowTemperature` |  |  | ITL |
| `LowTemperatureTransition` |  |  | NT |
| `Meltable` |  |  | 0 |
| `MenuSection` |  |  | SC_SOLIDS |
| `MenuVisible` |  |  | 1 |
| `Update` |  |  | &update |
| `colorKey` |  | { 		"g": "#5e807d", 		"s": "#638f8b", 		"S": "#679e99"} |  |
| `grain` |  | 0 } |  |
| `noMix` |  | true |  |
| `render_behavior` | outline glass (compute_raymarch.glsl) |  |  |
| `sim_behavior` | static (no move) |  |  |

## Source References

- GodotVoxelEngine shaders: `godot/project/shaders/compute_sim.glsl`, `compute_raymarch.glsl`, `compute_light.glsl`
- Sandboxels elements: `references/sandboxels/index.html` (split in `references/sandboxels/extracted/materials/`)
- Sandboxels behaviors/renderPresets/textures: `references/sandboxels/extracted/behaviors.js`, `renderPresets.js`, `textures.js`
- The Powder Toy elements: `references/The-Powder-Toy/src/simulation/elements/SAND.cpp`, `GLAS.cpp`