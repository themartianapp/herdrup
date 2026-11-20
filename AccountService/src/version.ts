// The Worker's version, as GET /v1/health reports it. Its own module: the entry module
// (src/index.ts) exports only its handler, which `wrangler dev` requires.
export const VERSION = "0.5.1";
