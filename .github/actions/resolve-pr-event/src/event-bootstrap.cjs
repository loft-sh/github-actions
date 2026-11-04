'use strict';

// Node actions initialize @actions/github before their entry point can adjust
// runner-provided event variables. Validate the resolver's file before loading.
const fs = require('node:fs');
try {
  const path = process.env.RESOLVED_PR_EVENT_PATH;
  const repository = process.env.GITHUB_REPOSITORY;
  if (!path || !repository) throw new Error();
  const event = JSON.parse(fs.readFileSync(path, 'utf8'));
  const number = event?.pull_request?.number;
  const eventRepository = event?.repository?.full_name;
  if (!Number.isSafeInteger(number) || number <= 0 ||
      typeof eventRepository !== 'string' ||
      eventRepository.toLowerCase() !== repository.toLowerCase()) throw new Error();
  process.env.GITHUB_EVENT_PATH = path;
  process.env.GITHUB_EVENT_NAME = 'pull_request_target';
} catch (_) {
  throw new Error('Unable to restore validated pull request event');
}
