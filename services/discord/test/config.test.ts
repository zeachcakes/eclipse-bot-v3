import assert from 'node:assert/strict';
import test from 'node:test';
import { readDiscordConfig } from '../src/config.ts';

const validEnv = {
  DISCORD_TOKEN: 'test-token-that-must-stay-private',
  DISCORD_APPLICATION_ID: '9007199254740993',
  DISCORD_GUILD_ID: '18446744073709551615',
};

test('reads trimmed configuration and preserves IDs above the safe integer range', () => {
  assert.deepEqual(readDiscordConfig({
    DISCORD_TOKEN: ` \t${validEnv.DISCORD_TOKEN}\n`,
    DISCORD_APPLICATION_ID: ` ${validEnv.DISCORD_APPLICATION_ID} `,
    DISCORD_GUILD_ID: `\n${validEnv.DISCORD_GUILD_ID}\t`,
  }), {
    token: validEnv.DISCORD_TOKEN,
    applicationId: validEnv.DISCORD_APPLICATION_ID,
    guildId: validEnv.DISCORD_GUILD_ID,
  });
});

test('accepts positive uint64 IDs without converting their string representation', () => {
  assert.deepEqual(readDiscordConfig({
    ...validEnv,
    DISCORD_APPLICATION_ID: '1',
    DISCORD_GUILD_ID: '00042',
  }), {
    token: validEnv.DISCORD_TOKEN,
    applicationId: '1',
    guildId: '00042',
  });
});

for (const setting of Object.keys(validEnv)) {
  for (const value of [undefined, '', ' \t\n']) {
    test(`rejects ${setting} when ${value === undefined ? 'missing' : JSON.stringify(value)}`, () => {
      assert.throws(() => readDiscordConfig({ ...validEnv, [setting]: value }), {
        message: `Missing required setting: ${setting}`,
      });
    });
  }
}

for (const setting of ['DISCORD_APPLICATION_ID', 'DISCORD_GUILD_ID']) {
  for (const value of [
    '0',
    '000',
    '-1',
    '+1',
    '1.5',
    '1e3',
    '0x10',
    '12 34',
    'not-an-id',
    '18446744073709551616',
    '99999999999999999999999999999999999999',
  ]) {
    test(`rejects invalid ${setting}: ${value}`, () => {
      assert.throws(() => readDiscordConfig({ ...validEnv, [setting]: value }), {
        message: `Invalid setting: ${setting}; expected a positive uint64 decimal ID`,
      });
    });
  }
}

test('configuration failures identify the setting without exposing its value or the token', () => {
  const privateValue = 'private-invalid-guild-value';
  assert.throws(() => readDiscordConfig({
    ...validEnv,
    DISCORD_GUILD_ID: privateValue,
  }), (error: unknown) => {
    assert.ok(error instanceof Error);
    assert.ok(error.message.includes('DISCORD_GUILD_ID'));
    assert.ok(!error.message.includes(privateValue));
    assert.ok(!error.message.includes(validEnv.DISCORD_TOKEN));
    return true;
  });
});
