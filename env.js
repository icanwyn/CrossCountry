// /api/env.js — Vercel serverless function
// Serves env.js to the browser with values pulled from Vercel env vars.
// Reference this in index.html BEFORE the main script:
//   <script src="/api/env"></script>

export default function handler(req, res) {
  const url  = process.env.SUPABASE_URL  || "";
  const anon = process.env.SUPABASE_ANON || "";
  res.setHeader("Content-Type", "application/javascript; charset=utf-8");
  res.setHeader("Cache-Control", "public, max-age=60, s-maxage=300");
  res.status(200).send(
    `window.SUPABASE_URL=${JSON.stringify(url)};` +
    `window.SUPABASE_ANON=${JSON.stringify(anon)};`
  );
}
