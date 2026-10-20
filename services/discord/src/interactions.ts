import { MessageFlags, type Interaction } from 'discord.js';
import type { Command } from './commands.ts';
import { logError } from './log-error.ts';

type ErrorReporter = (context: string, error: unknown) => void;

export function createInteractionHandler(
  guildId: string,
  commands: readonly Command[],
  reportError: ErrorReporter = logError,
): (interaction: Interaction) => Promise<void> {
  const commandsByName = new Map<string, Command>();
  for (const command of commands) {
    if (commandsByName.has(command.data.name)) {
      throw new Error(`Duplicate command: ${command.data.name}`);
    }
    commandsByName.set(command.data.name, command);
  }

  return async interaction => {
    if (!interaction.isChatInputCommand()) {
      return;
    }

    try {
      if (interaction.guildId !== guildId) {
        await interaction.reply({
          content: 'This bot is currently available only in its configured server.',
          flags: MessageFlags.Ephemeral,
        });
        return;
      }

      const command = commandsByName.get(interaction.commandName);
      if (!command) {
        await interaction.reply({
          content: 'This command is no longer available. Try /help.',
          flags: MessageFlags.Ephemeral,
        });
        return;
      }

      await command.execute(interaction);
    } catch (error) {
      reportError(`Command /${interaction.commandName} failed (${interaction.id})`, error);
      const content = 'Something went wrong while running this command. Please try again.';
      try {
        if (interaction.deferred && !interaction.replied) {
          await interaction.editReply({ content });
        } else if (interaction.replied) {
          await interaction.followUp({ content, flags: MessageFlags.Ephemeral });
        } else {
          await interaction.reply({ content, flags: MessageFlags.Ephemeral });
        }
      } catch (replyError) {
        reportError(`Could not send an error response (${interaction.id})`, replyError);
      }
    }
  };
}
