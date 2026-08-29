# Graphics

The GBA does not have a general-purpose graphics API. It has several display modes, four background layers, an object layer for sprites, palette memory, and video RAM with mode-specific layouts. Choosing the display mode early prevents a lot of wasted asset work.

Use Mode 3 when you need an immediate 16-bit framebuffer for a prototype or a small drawing-heavy effect. Use Mode 4 when a 256-color indexed framebuffer and page flipping fit the game. Use Mode 0 for tile backgrounds and sprites; it is the usual choice for games with scrolling maps, text, or many reusable tiles.

The [display reference](/reference/gba/) covers the register and memory types. The pages in this section focus on the design choices around them.
