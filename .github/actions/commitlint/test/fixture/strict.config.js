// Second fixture for the config-path smoke scenario. It has to reject what
// commitlint.config.js accepts, or a scenario pointing at it could not tell
// "the input reached the script" from "commitlint discovered the other file",
// which is what a broken config-path mapping silently falls back to.
//
// CommonJS for the same reason as its sibling: this repository has no
// package.json, so `.js` is not ESM.
module.exports = {
  rules: {
    'scope-empty': [2, 'always'],
  },
};
