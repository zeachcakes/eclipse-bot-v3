import assert from 'node:assert/strict';
import test from 'node:test';
import { MessageFlags, SlashCommandBuilder, type Interaction } from 'discord.js';
import type { Command } from '../src/commands.ts';
import { createInteractionHandler } from '../src/interactions.ts';

const guildId = '123456789012345678';
const errorContent = 'Something went wrong while running this command. Please try again.';

function command(name: string, execute: Command['execute']): Command {
  return {
    data: new SlashCommandBuilder().setName(name).setDescription('A test command.'),
    execute,
  };
}

function fakeInteraction(options: {
  name?: string;
  guildId?: string | null;
  chatInput?: boolean;
  deferred?: boolean;
  replied?: boolean;
  responseError?: Error;
} = {}) {
  const calls: { method: string; payload: unknown }[] = [];
  const fake = {
    id: 'interaction-42',
    commandName: options.name ?? 'known',
    guildId: options.guildId === undefined ? guildId : options.guildId,
    deferred: options.deferred ?? false,
    replied: options.replied ?? false,
    isChatInputCommand: () => options.chatInput ?? true,
    async reply(payload: unknown) {
      calls.push({ method: 'reply', payload });
      if (options.responseError) throw options.responseError;
    },
    async editReply(payload: unknown) {
      calls.push({ method: 'editReply', payload });
      if (options.responseError) throw options.responseError;
    },
    async followUp(payload: unknown) {
      calls.push({ method: 'followUp', payload });
      if (options.responseError) throw options.responseError;
    },
  };
  return { interaction: fake as unknown as Interaction, calls };
}

test('routes a slash command by name and passes the original interaction', async () => {
  const fake = fakeInteraction({ name: 'second' });
  const executed: unknown[] = [];
  const handle = createInteractionHandler(guildId, [
    command('first', async () => assert.fail('The first command must not run.')),
    command('second', async interaction => { executed.push(interaction); }),
  ]);

  await handle(fake.interaction);

  assert.deepEqual(executed, [fake.interaction]);
  assert.deepEqual(fake.calls, []);
});

for (const foreignGuild of ['987654321098765432', null]) {
  test(`rejects ${foreignGuild === null ? 'DMs' : 'another guild'} without executing commands`, async () => {
    const fake = fakeInteraction({ guildId: foreignGuild });
    const handle = createInteractionHandler(guildId, [
      command('known', async () => assert.fail('A command outside the configured guild must not run.')),
    ]);

    await handle(fake.interaction);

    assert.deepEqual(fake.calls, [{
      method: 'reply',
      payload: {
        content: 'This bot is currently available only in its configured server.',
        flags: MessageFlags.Ephemeral,
      },
    }]);
  });
}

test('ignores interactions that are not chat input commands', async () => {
  const fake = fakeInteraction({ chatInput: false });
  const handle = createInteractionHandler(guildId, [
    command('known', async () => assert.fail('A non-chat interaction must not execute a command.')),
  ]);

  await handle(fake.interaction);

  assert.deepEqual(fake.calls, []);
});

test('explains an unavailable command in an ephemeral reply', async () => {
  const fake = fakeInteraction({ name: 'removed' });
  const handle = createInteractionHandler(guildId, [
    command('known', async () => assert.fail('An unknown name must not execute another command.')),
  ]);

  await handle(fake.interaction);

  assert.deepEqual(fake.calls, [{
    method: 'reply',
    payload: {
      content: 'This command is no longer available. Try /help.',
      flags: MessageFlags.Ephemeral,
    },
  }]);
});

const acknowledgementStates = [
  { label: 'before acknowledgement', deferred: false, replied: false, method: 'reply' },
  { label: 'after deferral', deferred: true, replied: false, method: 'editReply' },
  { label: 'after replying', deferred: false, replied: true, method: 'followUp' },
  { label: 'after a deferred reply was sent', deferred: true, replied: true, method: 'followUp' },
];

for (const state of acknowledgementStates) {
  test(`reports command failures ${state.label} with the appropriate response`, async () => {
    const fake = fakeInteraction(state);
    const failure = new Error('Internal command failure that must not reach users.');
    const reports: { context: string; error: unknown }[] = [];
    const handle = createInteractionHandler(guildId, [
      command('known', async () => { throw failure; }),
    ], (context, error) => { reports.push({ context, error }); });

    await handle(fake.interaction);

    assert.deepEqual(reports, [{
      context: 'Command /known failed (interaction-42)',
      error: failure,
    }]);
    assert.deepEqual(fake.calls, [{
      method: state.method,
      payload: state.method === 'editReply'
        ? { content: errorContent }
        : { content: errorContent, flags: MessageFlags.Ephemeral },
    }]);
  });
}

test('reports and contains failure to send the error response', async () => {
  const commandError = new Error('Command failed.');
  const responseError = new Error('Discord is unavailable.');
  const fake = fakeInteraction({ responseError });
  const reports: { context: string; error: unknown }[] = [];
  const handle = createInteractionHandler(guildId, [
    command('known', async () => { throw commandError; }),
  ], (context, error) => { reports.push({ context, error }); });

  await assert.doesNotReject(handle(fake.interaction));

  assert.deepEqual(reports, [
    { context: 'Command /known failed (interaction-42)', error: commandError },
    { context: 'Could not send an error response (interaction-42)', error: responseError },
  ]);
  assert.equal(fake.calls.length, 1);
});

test('rejects duplicate command names when constructing the handler', () => {
  const duplicate = command('duplicate', async () => {});

  assert.throws(() => createInteractionHandler(guildId, [duplicate, duplicate]), {
    message: 'Duplicate command: duplicate',
  });
});
