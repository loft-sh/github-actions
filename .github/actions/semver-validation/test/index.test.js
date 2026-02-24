const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

describe('Semver Validation Action', () => {
  const indexPath = path.join(__dirname, '..', 'index.js');

  function parseOutputFile(filePath) {
    if (!fs.existsSync(filePath)) return {};
    const outputs = {};
    const lines = fs.readFileSync(filePath, 'utf8').split('\n');
    let i = 0;
    while (i < lines.length) {
      const heredoc = lines[i].match(/^([^=<]+)<<(.+)$/);
      if (heredoc) {
        const [, key, delimiter] = heredoc;
        const valueLines = [];
        i++;
        while (i < lines.length && lines[i] !== delimiter) {
          valueLines.push(lines[i]);
          i++;
        }
        outputs[key] = valueLines.join('\n');
      } else {
        const idx = lines[i].indexOf('=');
        if (idx > 0) outputs[lines[i].slice(0, idx)] = lines[i].slice(idx + 1);
      }
      i++;
    }
    return outputs;
  }

  function runAction(version) {
    const outputFile = path.join(os.tmpdir(), `gha_output_${process.pid}_${Date.now()}`);
    fs.writeFileSync(outputFile, '');
    try {
      const stdout = execSync('node ' + indexPath, {
        encoding: 'utf8',
        env: { ...process.env, INPUT_VERSION: version, GITHUB_OUTPUT: outputFile },
      });
      return { stdout, outputs: parseOutputFile(outputFile), success: true };
    } catch (error) {
      return {
        stdout: error.stdout || '',
        outputs: parseOutputFile(outputFile),
        success: false,
      };
    } finally {
      if (fs.existsSync(outputFile)) fs.unlinkSync(outputFile);
    }
  }

  describe('Valid semver versions', () => {
    test('should validate basic semver version', () => {
      const result = runAction('1.2.3');

      expect(result.success).toBe(true);
      expect(result.outputs.is_valid).toBe('true');
      expect(result.outputs.error_message).toBe('');
      expect(result.outputs.parsed_version).toContain('"major":1,"minor":2,"patch":3');
    });

    test('should validate semver with v prefix', () => {
      const result = runAction('v2.0.0');

      expect(result.success).toBe(true);
      expect(result.outputs.is_valid).toBe('true');
      expect(result.outputs.parsed_version).toContain('"major":2,"minor":0,"patch":0');
      expect(result.outputs.parsed_version).toContain('"raw":"v2.0.0"');
    });

    test('should validate prerelease version', () => {
      const result = runAction('1.0.0-alpha.1');

      expect(result.success).toBe(true);
      expect(result.outputs.is_valid).toBe('true');
      expect(result.outputs.parsed_version).toContain('"prerelease":"alpha.1"');
    });

    test('should validate version with build metadata', () => {
      const result = runAction('1.0.0+build.1');

      expect(result.success).toBe(true);
      expect(result.outputs.is_valid).toBe('true');
      expect(result.outputs.parsed_version).toContain('"build":"build.1"');
    });

    test('should validate complex version', () => {
      const result = runAction('2.1.0-beta.2+exp.sha.5114f85');

      expect(result.success).toBe(true);
      expect(result.outputs.is_valid).toBe('true');
      expect(result.outputs.parsed_version).toContain('"prerelease":"beta.2"');
      expect(result.outputs.parsed_version).toContain('"build":"exp.sha.5114f85"');
    });
  });

  describe('Invalid semver versions', () => {
    test('should reject incomplete version', () => {
      const result = runAction('1.2');

      expect(result.success).toBe(true);
      expect(result.outputs.is_valid).toBe('false');
      expect(result.outputs.parsed_version).toBe('');
      expect(result.outputs.error_message).toBe("Invalid semver format: '1.2'");
    });

    test('should reject non-numeric version', () => {
      const result = runAction('abc.def.ghi');

      expect(result.success).toBe(true);
      expect(result.outputs.is_valid).toBe('false');
      expect(result.outputs.error_message).toBe("Invalid semver format: 'abc.def.ghi'");
    });

    test('should reject empty version', () => {
      const result = runAction('');

      expect(result.success).toBe(false);
      expect(result.outputs.is_valid).toBe('false');
      expect(result.outputs.error_message).toContain('Input required and not supplied: version');
    });

    test('should reject version with leading zeros', () => {
      const result = runAction('01.2.3');

      expect(result.success).toBe(true);
      expect(result.outputs.is_valid).toBe('false');
    });
  });

  describe('Edge cases', () => {
    test('should handle very large version numbers', () => {
      const result = runAction('999999.999999.999999');

      expect(result.success).toBe(true);
      expect(result.outputs.is_valid).toBe('true');
    });

    test('should handle the original failing case', () => {
      const result = runAction('v100.0.0');

      expect(result.success).toBe(true);
      expect(result.outputs.is_valid).toBe('true');
      expect(result.outputs.parsed_version).toContain('"major":100');
    });
  });
});
