### Rules for Long-Running Processes
When running dev servers, file watchers, or long-running processes (e.g., `npm run dev`, `vite`,`npx ng serve`), you MUST run the command in the background (`background: true`) or append a background operator like `&`. Never run persistent processes in the foreground.

When starting background servers (e.g., `npm run dev`, `npm start`, `npx ng serve`, `bun run dev`, `bunx ng serve`), ALWAYS Append an ampersand (&) to the end of your command. This starts the process in the background immediately.

Never watch a long running process, instead you should from time to time read the last N lines to get status update