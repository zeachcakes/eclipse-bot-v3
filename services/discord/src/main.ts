import { Client, Events, GatewayIntentBits } from 'discord.js';
import { commands } from './commands.ts';
import { readDiscordConfig } from './config.ts';
import { createInteractionHandler } from './interactions.ts';
import { logError } from './log-error.ts';

async function main(): Promise<void> {
  const config = readDiscordConfig(process.env);
  const client = new Client({
    intents: [GatewayIntentBits.Guilds],
    allowedMentions: { parse: [] },
  });
  const handleInteraction = createInteractionHandler(config.guildId, commands);

  client.once(Events.ClientReady, readyClient => {
    console.info(`Discord bot ready as ${readyClient.user.tag}; guild ${config.guildId}.`);
  });
  client.on(Events.Error, error => logError('Discord client error', error));
  client.on(Events.InteractionCreate, interaction => {
    void handleInteraction(interaction).catch(error => {
      logError('Interaction handling failed', error);
    });
  });

  let shuttingDown = false;
  async function shutdown(signal: string): Promise<void> {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    console.info(`Received ${signal}; closing the Discord connection.`);
    await client.destroy();
  }

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      void shutdown(signal).catch(error => {
        logError('Discord shutdown failed', error);
        process.exitCode = 1;
      });
    });
  }

  try {
    await client.login(config.token);
  } catch (error) {
    await client.destroy();
    throw error;
  }
}

void main().catch(error => {
  logError('Discord bot failed to start', error);
  process.exitCode = 1;
});
