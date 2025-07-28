const core = require('@actions/core');
const semver = require('semver');

try {
  // Get the version input
  const version = core.getInput('version', { required: true });

  core.info(`Validating version: ${version}`);

  // Validate the version using semver library
  const isValid = semver.valid(version) !== null;

  // Set outputs
  core.setOutput('is_valid', isValid.toString());

  if (isValid) {
    const parsed = semver.parse(version);

    // Create a parsed version object
    const parsedVersion = {
      major: parsed.major,
      minor: parsed.minor,
      patch: parsed.patch,
      prerelease: parsed.prerelease.length > 0 ? parsed.prerelease.join('.') : null,
      build: parsed.build.length > 0 ? parsed.build.join('.') : null,
      raw: parsed.raw
    };

    core.setOutput('parsed_version', JSON.stringify(parsedVersion));
    core.setOutput('error_message', '');

    core.info(`✅ Version '${version}' is a valid semver`);
    core.info(`Parsed: ${JSON.stringify(parsedVersion, null, 2)}`);
  } else {
    core.setOutput('parsed_version', '');
    core.setOutput('error_message', `Invalid semver format: '${version}'`);

    core.warning(`❌ Version '${version}' is not a valid semver`);
  }

} catch (error) {
  core.setOutput('is_valid', 'false');
  core.setOutput('parsed_version', '');
  core.setOutput('error_message', error.message);

  core.setFailed(`Action failed with error: ${error.message}`);
}
