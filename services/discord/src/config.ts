export type DiscordConfig = {
  token: string;
  applicationId: string;
  guildId: string;
};

const MAX_DISCORD_ID = 18_446_744_073_709_551_615n;

function requireSetting(
  env: Readonly<Record<string, string | undefined>>,
  name: string,
): string {
  const value = env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required setting: ${name}`);
  }
  return value;
}

function requireDiscordId(
  env: Readonly<Record<string, string | undefined>>,
  name: string,
): string {
  const value = requireSetting(env, name);
  if (!/^[0-9]+$/.test(value)) {
    throw new Error(`Invalid setting: ${name}; expected a positive uint64 decimal ID`);
  }
  const numericValue = BigInt(value);
  if (numericValue === 0n || numericValue > MAX_DISCORD_ID) {
    throw new Error(`Invalid setting: ${name}; expected a positive uint64 decimal ID`);
  }
  return value;
}

export function readDiscordConfig(
  env: Readonly<Record<string, string | undefined>>,
): DiscordConfig {
  return {
    token: requireSetting(env, 'DISCORD_TOKEN'),
    applicationId: requireDiscordId(env, 'DISCORD_APPLICATION_ID'),
    guildId: requireDiscordId(env, 'DISCORD_GUILD_ID'),
  };
}
