/** Discord "Clyde" mark, monochrome — inherits the surrounding text colour. */
export function DiscordIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true" fill="currentColor">
      <path d="M20.3 4.4A19.8 19.8 0 0 0 15.4 3l-.2.4a13.2 13.2 0 0 1 4.5 2.3 15.4 15.4 0 0 0-15.4 0A13.2 13.2 0 0 1 8.8 3.4L8.6 3a19.8 19.8 0 0 0-4.9 1.4C.6 9.1-.2 13.6.2 18a19.9 19.9 0 0 0 6 3l1.3-2a12.7 12.7 0 0 1-2-1l.5-.4a14.2 14.2 0 0 0 12 0l.5.4a12.7 12.7 0 0 1-2 1l1.3 2a19.9 19.9 0 0 0 6-3c.5-5.1-.8-9.5-3.5-13.6ZM8.5 15.3c-1.2 0-2.1-1.1-2.1-2.4s.9-2.4 2.1-2.4 2.2 1.1 2.1 2.4c0 1.3-.9 2.4-2.1 2.4Zm7 0c-1.2 0-2.1-1.1-2.1-2.4s.9-2.4 2.1-2.4 2.2 1.1 2.1 2.4c0 1.3-.9 2.4-2.1 2.4Z" />
    </svg>
  );
}

export const DISCORD_URL = "https://discord.gg/9YMPHezpap";
