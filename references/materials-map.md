# Material Mapping (Initial)

```mermaid
flowchart LR
  subgraph OurEngine[GodotVoxelEngine]
    OE_Sand[Sand
id=1]
    OE_Glass[Glass
id=8]
    OE_Invis[Invisible Wall
id=9]
  end

  subgraph PowderToy[The Powder Toy]
    PT_Sand[SAND
Identifier=DEFAULT_PT_SAND]
    PT_Glass[GLAS
Identifier=DEFAULT_PT_GLAS]
  end

  subgraph Sandboxels[Sandboxels]
    SB_Sand[sand
behavior=POWDER]
    SB_Glass[glass
behavior=WALL]
  end

  OE_Sand --- PT_Sand
  OE_Sand --- SB_Sand
  OE_Glass --- PT_Glass
  OE_Glass --- SB_Glass
```

## Source Pointers

- GodotVoxelEngine
- Sand/glass/invisible IDs and behavior are defined in shaders and scene scripts.

- The Powder Toy
- Sand: `references/The-Powder-Toy/src/simulation/elements/SAND.cpp`
- Glass: `references/The-Powder-Toy/src/simulation/elements/GLAS.cpp`

- Sandboxels
- Sand: `references/sandboxels/index.html`
- Glass: `references/sandboxels/index.html`
