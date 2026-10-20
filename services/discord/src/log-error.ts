export function logError(context: string, error: unknown): void {
  const message = error instanceof Error ? error.message : 'Unknown error';
  console.error(`${context}: ${message}`);
}
