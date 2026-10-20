import {
  MessageFlags,
  SlashCommandBuilder,
  type ChatInputCommandInteraction,
} from 'discord.js';

export type Command = {
  readonly data: Pick<SlashCommandBuilder, 'name' | 'toJSON'>;
  execute(interaction: ChatInputCommandInteraction): Promise<void>;
};

export const commands: readonly Command[] = [
  {
    data: new SlashCommandBuilder()
      .setName('ping')
      .setDescription('Check whether the bot is responding.'),
    async execute(interaction) {
      await interaction.deferReply({ flags: MessageFlags.Ephemeral });
      await interaction.editReply({ content: 'Pong! The bot is responding.' });
    },
  },
  {
    data: new SlashCommandBuilder()
      .setName('help')
      .setDescription('List the available bot commands.'),
    async execute(interaction) {
      const content = commands
        .map(command => `/${command.data.name} — ${command.data.toJSON().description}`)
        .join('\n');
      await interaction.reply({ content, flags: MessageFlags.Ephemeral });
    },
  },
];
