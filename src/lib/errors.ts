/**
 * Supabase RPC errors are PostgrestError objects, NOT Error instances — so
 * `err instanceof Error` misses them and the Turkish message the database
 * raised ("Bu plaka için zaten açık bir bilet var") gets swallowed and
 * replaced by something generic.
 *
 * Those messages are the most useful thing on the screen when something is
 * refused at the gate. Surface them verbatim.
 */
export function rpcErrorText(err: unknown, fallback: string): string {
  const e = err as { message?: unknown; code?: unknown } | null
  // PGRST202 is PostgREST saying the function does not exist. It only happens
  // when a migration has not been run yet, and it answers in English with a
  // parameter list attached — nothing an operator at a barrier can act on, and
  // never the sentence to put in front of them. Every other message is the
  // database's own Turkish and goes through untouched.
  if (e?.code === 'PGRST202') return 'Bu özellik sunucuda henüz etkin değil.'
  const m = e?.message
  if (typeof m === 'string' && m.trim() !== '') {
    // PostgREST prefixes some errors; strip the noise, keep the sentence.
    return m.replace(/^(new row violates|ERROR:)\s*/i, '').trim()
  }
  return fallback
}

/** True when the failure looks like a lost connection rather than a refusal. */
export function agHatasiMi(err: unknown): boolean {
  const m = (err as { message?: unknown } | null)?.message
  if (typeof m !== 'string') return false
  return /fetch|network|failed to fetch|timeout|bağlantı/i.test(m)
}
