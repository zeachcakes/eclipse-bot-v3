import { REST, Routes } from 'discord.js';
import { commands } from './commands.ts';
import { readDiscordConfig } from './config.ts';
import { logError } from './log-error.ts';

async function registerCommands(): Promise<void> {
  const config = readDiscordConfig(process.env);
  const rest = new REST({ version: '10' }).setToken(config.token);
  await rest.put(
    Routes.applicationGuildCommands(config.applicationId, config.guildId),
    { body: commands.map(command => command.data.toJSON()) },
  );
  console.info(`Registered ${commands.length} commands in guild ${config.guildId}.`);
}

void registerCommands().catch(error => {
  logError('Command registration failed', error);
  process.exitCode = 1;
});
