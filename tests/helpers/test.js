#!/usr/bin/env node

const expectedEnvJson = process.env.EXPECTED_ENV_JSON;

if (!expectedEnvJson) {
  const env = Object.entries(process.env).sort(([left], [right]) =>
    left.localeCompare(right),
  );

  for (const [key, value] of env) {
    console.log(`${key}=${value ?? ""}`);
  }
  process.exit(0);
}

let expected;
try {
  expected = JSON.parse(expectedEnvJson);
} catch (error) {
  console.error(`Invalid EXPECTED_ENV_JSON: ${String(error)}`);
  process.exit(1);
}

if (expected === null || typeof expected !== "object" || Array.isArray(expected)) {
  console.error("EXPECTED_ENV_JSON must be a JSON object");
  process.exit(1);
}

const mismatches = [];
for (const [key, expectedValue] of Object.entries(expected)) {
  const actualValue = process.env[key] ?? "";
  if (actualValue !== String(expectedValue)) {
    mismatches.push(
      `${key}: expected=${JSON.stringify(String(expectedValue))} actual=${JSON.stringify(actualValue)}`,
    );
  }
}

if (mismatches.length > 0) {
  console.error("Environment assertion failed:");
  for (const mismatch of mismatches) {
    console.error(`- ${mismatch}`);
  }
  process.exit(1);
}

console.log(`Validated ${Object.keys(expected).length} environment variables.`);
