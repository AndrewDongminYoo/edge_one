// Generated from schemas/system-one-v1.schema.json.
// Schema SHA-256: b50719e9750907eaf07fd641c83148dfec1fcf33cae5e47426fe353dbc88a238
// Do not edit. Run: python3 tools/generate_contracts.py

export type StructuredValue = string | Record<string, unknown> | unknown[];
export type OptionalStructuredValue = StructuredValue | null;

export type ChoiceQuestion = {
  type: "choice";
  instructions?: OptionalStructuredValue;
  criteria: Record<string, OptionalStructuredValue>;
};

export type ScoreQuestion = {
  type: "score";
  instructions?: OptionalStructuredValue;
  criteria: [StructuredValue, ...StructuredValue[]];
};

export type NoulQuestion = {
  type: "noul";
  instructions?: OptionalStructuredValue;
  criteria?: Partial<Record<"true" | "false", OptionalStructuredValue>> | null;
};

export type ChoiceAnswer = {
  type: "choice";
  choice: string;
  probabilities: Record<string, number>;
  confidence: number;
};

export type ScoreAnswer = {
  type: "score";
  score: number;
  legend: Record<string, StructuredValue>;
  probabilities: Record<string, number>;
  confidence: number;
};

export type NoulAnswer = {
  type: "noul";
  noul: number;
};

export type Usage = {
  input_tokens: number;
  output_tokens: number;
};

export type SystemOneRequest = {
  state: StructuredValue;
  model: string;
  questions: Record<string, ChoiceQuestion | ScoreQuestion | NoulQuestion>;
};

export type SystemOneResponse = {
  model: string;
  answers: Record<string, ChoiceAnswer | ScoreAnswer | NoulAnswer>;
  usage: Usage;
  x_route?: "local" | "remote" | "auto";
  x_latency_ms?: number;
  x_engine?: unknown;
  [key: `x_${string}`]: unknown;
};

export type SystemOneQuestion = ChoiceQuestion | ScoreQuestion | NoulQuestion;
export type SystemOneAnswer = ChoiceAnswer | ScoreAnswer | NoulAnswer;
export type SystemOneV1 = SystemOneRequest | SystemOneResponse;
