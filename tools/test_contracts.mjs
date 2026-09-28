import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import Ajv from "ajv";

const schema = JSON.parse(
  readFileSync("schemas/system-one-v1.schema.json", "utf8"),
);
const ajv = new Ajv({
  allErrors: true,
  strict: true,
  allowMatchingProperties: true,
});
ajv.validateSchema(schema);
const validate = ajv.compile(schema);
const reactNativePackage = JSON.parse(
  readFileSync("packages/react-native-edge-one/package.json", "utf8"),
);
assert.ok(
  existsSync(join("packages/react-native-edge-one", reactNativePackage.types)),
  "React Native package types must point to the generated contract",
);

function expectValid(value) {
  assert.equal(validate(value), true, JSON.stringify(validate.errors));
}

function expectInvalid(value) {
  assert.equal(
    validate(value),
    false,
    "Expected the schema to reject this value",
  );
}

const request = {
  state: { ticket: ["urgent", 3] },
  model: "model-revision",
  questions: {
    team: {
      type: "choice",
      instructions: ["Pick", { locale: "en" }],
      criteria: { billing: null, shipping: { hint: "parcel" } },
    },
    urgency: { type: "noul", criteria: { true: "urgent", false: "routine" } },
    impact: { type: "score", criteria: ["low", { level: "high" }] },
  },
};
expectValid(request);
expectValid({
  ...request,
  questions: { urgency: { type: "noul", criteria: null } },
});
expectValid({
  ...request,
  questions: { impact: { type: "score", criteria: ["one"] } },
});
expectInvalid({
  ...request,
  questions: { impact: { type: "score", criteria: [] } },
});
expectInvalid({
  ...request,
  model: undefined,
});
expectInvalid({
  ...request,
  questions: { urgency: { type: "noul", criteria: { maybe: "x" } } },
});
expectInvalid({ ...request, state: 42 });
expectInvalid({
  ...request,
  questions: { team: { type: "choice", criteria: { bad: 42 } } },
});

const response = {
  model: "model-revision",
  answers: {
    team: {
      type: "choice",
      choice: "billing",
      probabilities: { billing: 0.8, shipping: 0.2 },
      confidence: 0.7,
    },
    urgency: { type: "noul", noul: 0.8 },
    impact: {
      type: "score",
      score: 1.6,
      legend: { 0: "low", 1: "high" },
      probabilities: { 0: 0.4, 1: 0.6 },
      confidence: 0.2,
    },
  },
  usage: { input_tokens: 12, output_tokens: 2 },
  x_route: "local",
  x_latency_ms: 120,
  x_engine: { quantization: "Q4_K_M" },
  x_trace: ["local"],
};
expectValid(response);
expectInvalid({ ...response, x_route: "unknown" });
expectInvalid({
  ...response,
  answers: { urgency: { type: "noul", noul: 1.5 } },
});
expectInvalid({ ...response, answers: { urgency: { noul: 0.8 } } });
expectInvalid({ ...response, answers: {} });
expectInvalid({
  ...response,
  answers: { team: { ...response.answers.team, probabilities: {} } },
});
expectInvalid({
  ...response,
  answers: { impact: { ...response.answers.impact, legend: {} } },
});
expectInvalid({ ...response, usage: { input_tokens: 12 } });
expectInvalid({
  ...response,
  usage: { input_tokens: 12, output_tokens: 2, debug: true },
});
expectInvalid({
  ...response,
  answers: {
    team: {
      type: "choice",
      choice: "billing",
      probabilities: { billing: 1.5 },
      confidence: 0.7,
    },
  },
});
expectInvalid({ ...response, unrelated: true });
console.log("System One schema fixtures passed");
