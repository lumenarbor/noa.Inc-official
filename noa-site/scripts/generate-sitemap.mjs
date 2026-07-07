import fs from 'fs';
import path from 'path';

const SITE_URL = 'https://noa-place.co.jp';
const ROOT = process.cwd();
const PUBLIC_DIR = path.join(ROOT, 'public');
const UPDATES_JSON_PATH = path.join(PUBLIC_DIR, 'content', 'updates.json');
const SITEMAP_PATH = path.join(PUBLIC_DIR, 'sitemap.xml');

const STATIC_PAGES = [
  { loc: `${SITE_URL}/`, changefreq: 'weekly', priority: '1.0' },
  { loc: `${SITE_URL}/?page=philosophy`, changefreq: 'monthly', priority: '0.8' },
  { loc: `${SITE_URL}/?page=services`, changefreq: 'monthly', priority: '0.8' },
  { loc: `${SITE_URL}/?page=contact`, changefreq: 'monthly', priority: '0.8' },
  { loc: `${SITE_URL}/?page=privacy`, changefreq: 'yearly', priority: '0.3' },
  { loc: `${SITE_URL}/?page=terms`, changefreq: 'yearly', priority: '0.3' }
];

function escapeXml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function toUrlEntry({ loc, changefreq, priority, lastmod }) {
  return [
    '  <url>',
    `    <loc>${escapeXml(loc)}</loc>`,
    lastmod ? `    <lastmod>${escapeXml(lastmod)}</lastmod>` : null,
    changefreq ? `    <changefreq>${escapeXml(changefreq)}</changefreq>` : null,
    priority ? `    <priority>${escapeXml(priority)}</priority>` : null,
    '  </url>'
  ]
    .filter(Boolean)
    .join('\n');
}

function normalizeDate(value) {
  const s = String(value || '').trim();
  if (!s) return '';
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return '';
  return d.toISOString().split('T')[0];
}

function loadUpdates() {
  if (!fs.existsSync(UPDATES_JSON_PATH)) {
    console.warn(`updates.json not found: ${UPDATES_JSON_PATH}`);
    return [];
  }

  const raw = fs.readFileSync(UPDATES_JSON_PATH, 'utf8');
  const json = JSON.parse(raw);
  const items = Array.isArray(json.items) ? json.items : [];

  return items
    .filter((item) => item && item.published !== false)
    .map((item) => {
      const slug = String(item.slug || '').trim();
      if (!slug) return null;

      return {
        loc: `${SITE_URL}/?u=${encodeURIComponent(slug)}`,
        changefreq: 'monthly',
        priority: '0.6',
        lastmod: normalizeDate(item.date || item.updatedAt || item.lastmod)
      };
    })
    .filter(Boolean);
}

function buildSitemapXml(urls) {
  const body = urls.map(toUrlEntry).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset
  xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
>
${body}
</urlset>
`;
}

function main() {
  const updatePages = loadUpdates();
  const allUrls = [...STATIC_PAGES, ...updatePages];
  const xml = buildSitemapXml(allUrls);

  fs.writeFileSync(SITEMAP_PATH, xml, 'utf8');
  console.log(`sitemap generated: ${SITEMAP_PATH}`);
  console.log(`total urls: ${allUrls.length}`);
}

main();
