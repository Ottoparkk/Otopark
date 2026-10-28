// Minimal Deno surface the Edge Functions use — for `npm run typecheck:functions`
// only. Kept outside supabase/functions so it never meets real Deno types.
declare const Deno: {
  env: { get(key: string): string | undefined }
  serve(handler: (req: Request) => Response | Promise<Response>): unknown
}
