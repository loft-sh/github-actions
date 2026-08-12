// Fixture for the composite smoke job. Deliberately self-contained - no
// `extends` - so the npx path can resolve it with only the CLI installed.
//
// CommonJS because this repository has no package.json, so `.js` is not ESM.
module.exports = {
  rules: {
    'type-empty': [2, 'never'],
    'type-enum': [2, 'always', ['chore', 'ci', 'feat', 'fix']],
    'subject-empty': [2, 'never'],
  },
};
