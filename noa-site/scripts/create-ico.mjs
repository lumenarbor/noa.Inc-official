/**
 * Create a minimal favicon.ico containing 16x16 and 32x32 PNG images.
 * ICO format with embedded PNG data (supported by all modern browsers).
 * Usage: node scripts/create-ico.mjs
 */
import { readFileSync, writeFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const publicDir = join(__dirname, '..', 'public');

const images = [
  { path: join(publicDir, 'favicon-16x16.png'), size: 16 },
  { path: join(publicDir, 'favicon-32x32.png'), size: 32 },
];

const pngData = images.map(img => ({
  data: readFileSync(img.path),
  size: img.size,
}));

// ICO header: 6 bytes
// Each directory entry: 16 bytes
// Then PNG data for each image
const headerSize = 6;
const entrySize = 16;
const numImages = pngData.length;
const dirSize = entrySize * numImages;
let dataOffset = headerSize + dirSize;

// Build ICO header
const header = Buffer.alloc(headerSize);
header.writeUInt16LE(0, 0);      // Reserved
header.writeUInt16LE(1, 2);      // Type: 1 = ICO
header.writeUInt16LE(numImages, 4); // Number of images

// Build directory entries
const entries = [];
for (const img of pngData) {
  const entry = Buffer.alloc(entrySize);
  entry.writeUInt8(img.size === 256 ? 0 : img.size, 0);  // Width (0 = 256)
  entry.writeUInt8(img.size === 256 ? 0 : img.size, 1);  // Height
  entry.writeUInt8(0, 2);         // Color palette
  entry.writeUInt8(0, 3);         // Reserved
  entry.writeUInt16LE(1, 4);      // Color planes
  entry.writeUInt16LE(32, 6);     // Bits per pixel
  entry.writeUInt32LE(img.data.length, 8); // Size of image data
  entry.writeUInt32LE(dataOffset, 12);     // Offset to image data
  entries.push(entry);
  dataOffset += img.data.length;
}

// Combine all parts
const ico = Buffer.concat([
  header,
  ...entries,
  ...pngData.map(img => img.data),
]);

const outPath = join(publicDir, 'favicon.ico');
writeFileSync(outPath, ico);
console.log(`✓ favicon.ico created (${ico.length} bytes) with ${numImages} images`);
