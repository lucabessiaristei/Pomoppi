// Pixel drawing primitives for Pomoppi widget. Canvas coords are logical pixels,
// scaled by the caller before drawing. All functions work at logical scale.

window.Draw = {
  fillRect(ctx, x, y, w, h, color) {
    ctx.fillStyle = color;
    ctx.fillRect(x, y, w, h);
  },

  // Four fills, not strokeRect: a 1px stroke straddles the pixel boundary and
  // comes out grey and blurred once the context is scaled up.
  drawBorder(ctx, x, y, w, h, color) {
    this.fillRect(ctx, x, y, w, 1, color);
    this.fillRect(ctx, x, y + h - 1, w, 1, color);
    this.fillRect(ctx, x, y, 1, h, color);
    this.fillRect(ctx, x + w - 1, y, 1, h, color);
  },

  drawGrid(ctx, grid, x, y, colorMap = {}) {
    const defaultColorMap = { '#': '#000000', 'w': '#FFFFFF', 'g': '#C8C8C8' };
    const colors = { ...defaultColorMap, ...colorMap };

    for (let row = 0; row < grid.length; row++) {
      const line = grid[row];
      for (let col = 0; col < line.length; col++) {
        const char = line[col];
        if (char !== '.' && char !== '0') {
          const color = colors[char] || '#000000';
          this.fillRect(ctx, x + col, y + row, 1, 1, color);
        }
      }
    }
  },

  drawIcon(ctx, iconGrid, x, y, color = '#000000') {
    for (let row = 0; row < iconGrid.length; row++) {
      const line = iconGrid[row];
      for (let col = 0; col < line.length; col++) {
        if (line[col] === '1') {
          this.fillRect(ctx, x + col, y + row, 1, 1, color);
        }
      }
    }
  },

  // Glyphs are not all the same width -- ':' is 1px, digits are 3px -- so the
  // advance has to come from the glyph itself. Returns width in logical px.
  measureText(text, scale = 1, glyphs = {}, gap = 1) {
    let w = 0;
    for (const char of text) {
      const g = glyphs[char];
      if (!g) continue;
      w += g[0].length + gap;
    }
    return w > 0 ? (w - gap) * scale : 0;
  },

  drawText(ctx, text, x, y, scale, color = '#000000', glyphs = {}, gap = 1) {
    let px = 0;
    for (const char of text) {
      const g = glyphs[char];
      if (!g) continue;
      this._drawGlyph(ctx, g, x + px * scale, y, scale, color);
      px += g[0].length + gap;
    }
    return px > 0 ? (px - gap) * scale : 0;
  },

  _drawGlyph(ctx, glyph, x, y, scale, color) {
    for (let row = 0; row < glyph.length; row++) {
      const line = glyph[row];
      for (let col = 0; col < line.length; col++) {
        if (line[col] === '1') {
          this.fillRect(ctx, x + col * scale, y + row * scale, scale, scale, color);
        }
      }
    }
  },

  drawRect(ctx, x, y, w, h, color = '#000000') {
    this.fillRect(ctx, x, y, w, h, color);
  },

  drawRoundRect(ctx, x, y, w, h, color, filled = false) {
    // Draw a rectangle with rounded corners by omitting 4 extreme corner pixels
    if (filled) {
      // Fill the interior
      if (w > 2 && h > 2) {
        this.fillRect(ctx, x + 1, y, w - 2, h, color);
        this.fillRect(ctx, x, y + 1, 1, h - 2, color);
        this.fillRect(ctx, x + w - 1, y + 1, 1, h - 2, color);
      }
    } else {
      // Draw border with corners omitted
      if (w > 2) {
        this.fillRect(ctx, x + 1, y, w - 2, 1, color);           // top
        this.fillRect(ctx, x + 1, y + h - 1, w - 2, 1, color);  // bottom
      }
      if (h > 2) {
        this.fillRect(ctx, x, y + 1, 1, h - 2, color);           // left
        this.fillRect(ctx, x + w - 1, y + 1, 1, h - 2, color);  // right
      }
    }
  }
};
