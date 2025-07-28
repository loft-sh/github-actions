const { execSync } = require('child_process');
const path = require('path');

describe('Semver Validation Action', () => {
  const indexPath = path.join(__dirname, '..', 'index.js');

  // Helper function to run the action as a subprocess
  function runAction(version) {
    try {
      const result = execSync(`INPUT_VERSION="${version}" node ${indexPath}`, {
        encoding: 'utf8',
        env: { ...process.env, INPUT_VERSION: version }
      });
      return { stdout: result, success: true };
    } catch (error) {
      return { stdout: error.stdout || '', stderr: error.stderr || '', success: false };
    }
  }

  describe('Valid semver versions', () => {
    test('should validate basic semver version', () => {
      const result = runAction('1.2.3');

      expect(result.success).toBe(true);
      expect(result.stdout).toContain('::set-output name=is_valid::true');
      expect(result.stdout).toContain('::set-output name=error_message::');
      expect(result.stdout).toContain('"major":1,"minor":2,"patch":3');
    });

    test('should validate semver with v prefix', () => {
      const result = runAction('v2.0.0');

      expect(result.success).toBe(true);
      expect(result.stdout).toContain('::set-output name=is_valid::true');
      expect(result.stdout).toContain('"major":2,"minor":0,"patch":0');
      expect(result.stdout).toContain('"raw":"v2.0.0"');
    });

    test('should validate prerelease version', () => {
      const result = runAction('1.0.0-alpha.1');

      expect(result.success).toBe(true);
      expect(result.stdout).toContain('::set-output name=is_valid::true');
      expect(result.stdout).toContain('"prerelease":"alpha.1"');
    });

    test('should validate version with build metadata', () => {
      const result = runAction('1.0.0+build.1');

      expect(result.success).toBe(true);
      expect(result.stdout).toContain('::set-output name=is_valid::true');
      expect(result.stdout).toContain('"build":"build.1"');
    });

    test('should validate complex version', () => {
      const result = runAction('2.1.0-beta.2+exp.sha.5114f85');

      expect(result.success).toBe(true);
      expect(result.stdout).toContain('::set-output name=is_valid::true');
      expect(result.stdout).toContain('"prerelease":"beta.2"');
      expect(result.stdout).toContain('"build":"exp.sha.5114f85"');
    });
  });

  describe('Invalid semver versions', () => {
    test('should reject incomplete version', () => {
      const result = runAction('1.2');

      expect(result.success).toBe(true); // Script doesn't exit with error for invalid semver
      expect(result.stdout).toContain('::set-output name=is_valid::false');
      expect(result.stdout).toContain('::set-output name=parsed_version::');
      expect(result.stdout).toContain("Invalid semver format: '1.2'");
    });

    test('should reject non-numeric version', () => {
      const result = runAction('abc.def.ghi');

      expect(result.success).toBe(true);
      expect(result.stdout).toContain('::set-output name=is_valid::false');
      expect(result.stdout).toContain("Invalid semver format: 'abc.def.ghi'");
    });

    test('should reject empty version', () => {
      const result = runAction('');

      expect(result.success).toBe(false); // Action fails due to required input
      expect(result.stdout).toContain('::set-output name=is_valid::false');
      expect(result.stdout).toContain('Input required and not supplied: version');
    });

    test('should reject version with leading zeros', () => {
      const result = runAction('01.2.3');

      expect(result.success).toBe(true);
      expect(result.stdout).toContain('::set-output name=is_valid::false');
    });
  });

  describe('Edge cases', () => {
    test('should handle very large version numbers', () => {
      const result = runAction('999999.999999.999999');

      expect(result.success).toBe(true);
      expect(result.stdout).toContain('::set-output name=is_valid::true');
    });

    test('should handle the original failing case', () => {
      const result = runAction('v100.0.0');

      expect(result.success).toBe(true);
      expect(result.stdout).toContain('::set-output name=is_valid::true');
      expect(result.stdout).toContain('"major":100');
    });
  });
});
