# 온디바이스 System One 런타임 블루프린트

Sep 27, 2026 · @Dongmin Yu

## 개요

Flutter와 React Native 앱에서 TypeSafe `/v1/systemone`과 같은 스키마의 결정(Choice / Score / Noul)을 **기기 안에서** 내리고, 확신이 낮을 때만 원격 Jev로 넘기는 런타임을 만든다. 작업명은 `edge_one`(가칭)이다.

### 목표

- 요청·응답이 `/v1/systemone`과 바이트 수준에서 호환된다. 같은 요청 JSON을 로컬 엔진, 원격 Jev, 오픈 모델 서버(Kev, jev-style 등) 어디로 보내도 같은 타입의 응답이 온다.
- iOS·Android에서 0.6\~0.8B 모델로 Choice 1개(옵션 ≤ 8, state ≤ 512 토큰)를 중급 기기 기준 p50 300ms 안에 처리한다. 이 수치는 M1 스파이크에서 실측해 확정한다.
- confidence gate로 로컬/원격을 섞고, 그 threshold를 사용자 라벨 데이터로 적합하는 도구를 함께 제공한다.

### 비목표

- 텍스트 생성, 채팅, 에이전트 루프. 이 런타임은 결정만 한다.
- TypeSafe 모델의 재현. RLCD 같은 학습 기법이나 Jev 수준의 정확도는 목표가 아니다. 오픈 모델을 옵션 logit으로 읽는 공개된 방식만 쓴다.
- 비전 입력. PocketJev류의 카메라 결정은 v2 이후로 미룬다.

**성공 기준**: pub.dev와 npm에 v0.1 게시, 공개 벤치마크 리포트 1편(로컬 vs Jev vs 하이브리드의 정확도·지연·비용), 데모 앱 1개.

## 호환 대상 계약: `/v1/systemone`

런타임의 공개 계약은 TypeSafe [API reference](https://docs.typesafe.ai/api.md)를 그대로 따른다. 요청은 `state`, `model`, `questions` 맵이고, 응답은 같은 키 아래 `answers`와 `usage`를 돌려준다. 이 스키마를 내부 표현으로 삼으면 백엔드를 바꿔도 앱 코드는 그대로다.

| 타입   | 요청 `criteria`                 | 응답 필드                                                        | 한도            |
| ------ | ------------------------------- | ---------------------------------------------------------------- | --------------- |
| Noul   | 선택, `{true, false}` 설명      | `noul` (0\~1, yes 확률)                                          | confidence 없음 |
| Choice | 필수, 옵션 → 설명(null 허용) 맵 | `choice`, `probabilities`(합 1), `confidence`                    | 옵션 최대 255   |
| Score  | 필수, 순서 있는 레벨 배열       | `score`(확률 가중 평균), `legend`, `probabilities`, `confidence` | 레벨 2\~10      |

`instructions`와 `criteria` 값은 문자열뿐 아니라 객체·배열도 받는다. 로컬 엔진은 이를 프롬프트로 직렬화할 때 원본 JSON 구조를 유지해야 한다.

**confidence**: [Confidence 문서](https://docs.typesafe.ai/confidence.md)에 따르면 분포가 한 옵션에 몰리면 1.0, 고르게 퍼질수록 낮아진다. 3지선다 예시로 `(n × p_max − 1) / (n − 1)` 근사식을 보여준다. 로컬 엔진은 이 식을 n개 옵션으로 일반화해 같은 필드를 채운다. 원격 값과 정확히 같은 정의라는 보장은 없으므로 `confidence_source` 메타데이터를 따로 둔다.

**에러 매핑**: 원격은 401, 422, 429, 529를 쓴다. 로컬 엔진은 스키마 위반을 422 동등 예외로, 모델 미로드·메모리 부족은 별도 `EngineUnavailable`로 던져 라우터가 원격 폴백 여부를 판단하게 한다.

**확장 필드**(원격으로는 보내지 않음): `x_route`(`local` / `remote` / `auto`), `x_latency_ms`, `x_engine`(모델 id·양자화). 응답에 이 필드를 추가해도 원격 SDK 파서가 깨지지 않도록 `x_` 접두어로 격리한다.

## 온디바이스 추론 원리

디코딩은 하지 않는다. prefill 한 번으로 옵션별 점수를 읽고 softmax를 적용한다. 그래서 0.5\~0.8B 모델로도 모바일에서 수백 ms대 latency를 기대할 수 있다. 공개 구현을 보면 방식은 두 갈래다.

| 방식                    | 대표 구현                                                                                                              | 읽는 값                                                   | 런타임 요구                     | 판단                 |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | ------------------------------- | -------------------- |
| A. 옵션별 verdict logit | [jev-style](https://github.com/lawrence3699/jev-style) (Qwen3.5-0.8B fine-tune, llama.cpp용 `jev-score` 스코어러 동봉) | 옵션별 `" ->"` 위치의 `" yes"` logit과 `" no"` logit 차이 | 표준 llama.cpp logits API       | **M1\~M3 기본 경로** |
| B. Pointer head         | [kev](https://github.com/jaredpalmer/kev) (Qwen2.5-0.5B + LoRA + readout head)                                         | `</opt>`와 `<decide>` 위치의 hidden state 내적            | hidden state 출력 + 커스텀 head | v2 실험 경로         |

**방식 A의 흐름**: state와 질문을 모델의 `macjev-render-v1` 템플릿으로 렌더링하고, 각 옵션 뒤에 `" ->"` 판정 위치를 둔다.
각 판정 위치에서 `" yes"` logit과 `" no"` logit의 차이를 구하고, 온도 T로 나눈 뒤 옵션 전체에 softmax를 적용한다.
마지막 위치에서 A/B/C 토큰을 읽는 방식은 선택한 모델의 판정 방식과 다르다.
Noul은 이진 분포로, Score는 레벨별 분포의 가중 평균으로 API 응답에 매핑한다.
T는 모델이 배포한 readout 설정에서 가져오며, category를 지정하지 않으면 global temperature를 쓴다.
근거는 고정 revision의 [runtime](https://huggingface.co/chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF/blob/edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c/jev_style_decision_gguf.py)과 [readout 설정](https://huggingface.co/chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF/blob/edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c/readout_config.json)이다.

```plaintext
logits_i = llama_get_logits_ith(ctx, slot_index[i])
z_i      = (logits_i[yes_token] - logits_i[no_token]) / T
p      = softmax(z)
conf   = (K · max(p) − 1) / (K − 1)
```

**옵션 수 정책**: verdict 방식은 옵션마다 판정 위치를 두므로 A/B/C 단일 토큰 라벨 수에 제한받지 않는다.
실제 제약은 질문·옵션·판정 위치의 토큰 예산과 한 번에 출력할 logit 행 수다.
v0.1의 로컬 옵션 상한 26개는 초기 범위를 제한하기 위한 정책으로 유지한다.
초과 시 원격 호출이 허용되는 경우에만 원격으로 라우팅한다.

**다중 질문을 한 번에 처리하기**: 선택한 모델은 attention과 recurrent 레이어를 함께 쓰므로, prefix를 분할하는 위치와 microbatch 구성에 따라 확률이 달라질 수 있다.
upstream `exact` 모드는 완전한 microbatch 블록만 seq 0에 prefill하고, `llama_memory_seq_cp`로 각 질문에 공유한 뒤 나머지를 순차 처리한다.
기본 microbatch가 1,024토큰이므로 이보다 짧은 state prefix는 공유하지 않는다.
`batched` 모드는 전체 prefix를 공유하고 질문을 함께 처리하지만, upstream은 개별 추론과 최대 0.002의 확률 차이를 보고했다.
따라서 공유 자체를 정확성이나 속도 이득으로 간주하지 않고, M0에서 두 모드를 각각 개별 prefill과 비교한다.
근거는 고정 revision의 [GGUF 모델 문서](https://huggingface.co/chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF/blob/edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c/README.md)이다.

**방식 B를 뒤로 미루는 이유**: pointer head는 옵션 수 제한이 없고 kev 보고 기준 캘리브레이션도 좋다(held-out ECE 0.065, 온도 보정 후 0.031). 하지만 hidden state를 꺼내 별도 head를 돌려야 하고, 가중치가 LoRA + head라서 GGUF 변환 파이프라인을 직접 만들어야 한다. 또 kev 수치는 학습 데이터셋의 test split이라 in-distribution이다. 엔진 인터페이스를 `score(prefix, branches) → distributions`로 추상화해 두면 나중에 B를 끼우기 쉽다.

## 전체 아키텍처

추론 코어는 C++ 하나로 두고, Flutter와 RN은 얇은 바인딩만 갖는다. 앱 코드는 SystemOne 계약만 알고, 어느 백엔드가 답했는지는 `x_route`로만 드러난다.

&#91;embedded content: edge\_one 레이어 구조 · 앱 2종, 백엔드 3종\]

| 패키지                  | 언어                 | 배포처                      | 역할                                                             |
| ----------------------- | -------------------- | --------------------------- | ---------------------------------------------------------------- |
| `edge_one_core`         | C++17, CMake         | GitHub 릴리스(소스)         | 렌더러, 스코어러, llama.cpp pin. 두 바인딩이 공유                |
| `edge_one`              | pure Dart            | pub.dev                     | 계약 타입, HybridRouter, Remote/Server 백엔드. Flutter 의존 없음 |
| `edge_one_flutter`      | Dart + FFI           | pub.dev                     | LocalEngine, 모델 다운로드·캐시, iOS/Android 빌드                |
| `react-native-edge-one` | TS + C++ TurboModule | npm                         | 같은 계약의 TS 타입, JSI로 코어 직접 호출                        |
| `edge-one-calibrate`    | Dart CLI             | pub.dev (`dart pub global`) | 라벨 JSONL로 threshold·temperature 적합, CI 회귀 검사            |

모노레포(melos + pnpm workspace)로 두되, 코어의 llama.cpp는 git submodule로 특정 커밋에 고정한다. 계약 타입은 JSON Schema 하나에서 Dart와 TS를 코드 생성해 두 언어가 어긋나지 않게 한다.

## 네이티브 레이어

엔진은 llama.cpp 하나로 시작한다. GGUF 하나로 iOS(Metal)와 Android(CPU, 이후 Vulkan/OpenCL)를 모두 덮고, jev-style이 Q4\_K\_M GGUF와 llama.cpp 스코어러를 이미 배포하고 있기 때문이다.

| 엔진                | 장점                                                   | 단점                                           | 결정                    |
| ------------------- | ------------------------------------------------------ | ---------------------------------------------- | ----------------------- |
| llama.cpp           | 양 플랫폼 단일 코드, GGUF 생태계, logits·KV 시퀀스 API | Android GPU 가속은 기기 편차 큼                | **v0.1 유일 엔진**      |
| MLX (iOS)           | Apple 실리콘 최적화, jev-style MLX 빌드 존재           | iOS 전용, Swift 바인딩 필요, 두 번째 코드 경로 | v0.3 이후 선택적 백엔드 |
| ExecuTorch / LiteRT | Android NPU 경로                                       | 모델별 export 작업, logit 읽기 커스텀          | 보류                    |

### C API (`edge_one_core`)

바인딩 두 개가 같은 ABI를 쓰도록 C 인터페이스를 좁게 유지한다. 요청·응답은 JSON 문자열로 주고받는다. 호출당 수백 ms인 작업이라 직렬화 비용은 무시할 수 있고, 대신 ABI가 스키마 변경에 흔들리지 않는다.

```c
typedef struct eo_engine eo_engine;

eo_engine* eo_open(const char* model_path, const char* manifest_json, char** err);
// request_json: /v1/systemone 요청. 반환: 응답 JSON (eo_free로 해제)
char* eo_evaluate(eo_engine*, const char* request_json, int32_t* status);
void  eo_cancel(eo_engine*);          // 진행 중 decode 중단 플래그
void  eo_close(eo_engine*);
void  eo_free(char*);
```

내부 파이프라인은 다음 순서다.

1. 요청 검증: 옵션 수, 레벨 수, 토큰 예산. 위반 시 422 동등 status를 반환한다.
2. 렌더링: 모델 manifest의 템플릿으로 state 프리픽스와 질문별 branch 텍스트를 만든다. 사용자 텍스트가 구분자를 위조하지 못하게 이스케이프한다(kev의 boundary forgery 테스트를 회귀 테스트로 가져온다).
3. state prefill: M0에서 검증한 공유 모드에 따라 prefix를 seq 0에 넣는다. 공유하지 않는 경우 질문마다 전체 입력을 prefill한다.
4. branch 분기: `llama_memory_seq_cp`로 검증한 prefix만 각 질문에 공유하고, exact 또는 batched 모드에 따라 나머지를 처리한다.
5. 읽기: 옵션별 verdict 위치에서 yes/no logit 차이를 구하고, `/T`, softmax, confidence를 계산한다.
6. 정리: `llama_memory_seq_rm`으로 1..N을 지운다. seq 0은 같은 state가 다시 올 때를 대비해 해시로 캐시한다.

### Flutter 바인딩

Dart 3.10부터 [build hooks가 stable](https://blog.dart.dev/announcing-dart-3-10-ea8b952b6088)이다. `hook/build.dart`에서 네이티브 코드를 컴파일하거나 미리 빌드된 라이브러리를 받아 패키지에 번들할 수 있어서, 플랫폼별 CMake·Gradle·SPM 파일을 따로 관리할 필요가 없다. `edge_one_flutter`는 `hook/build.dart`에서 CMake로 `edge_one_core`를 빌드하고 `@Native` FFI 바인딩(ffigen 생성)으로 호출한다. Apple 플랫폼은 [동적 라이브러리 이름을 아키텍처 간에 일관되게](https://dart.dev/tools/hooks) 유지해야 XCFramework가 제대로 생성된다.

`eo_evaluate`는 블로킹 호출이므로 UI isolate에서 부르면 안 된다. 엔진 하나당 전용 long-lived isolate를 두고 `SendPort`로 요청을 직렬화한다. `Isolate.run`을 매번 쓰면 모델을 다시 로드하게 되므로 쓰지 않는다. 취소는 `eo_cancel`로 네이티브 플래그를 세우는 방식이다.

### React Native 바인딩

C++ TurboModule로 JSI에서 `edge_one_core`를 직접 부른다. 추론은 별도 스레드에서 돌리고 결과는 `Promise`로 돌려준다. react-native-step-counter에서 쓴 New Architecture 구성을 그대로 재사용할 수 있다. 네이티브 라이브러리는 iOS에서 XCFramework(podspec `vendored_frameworks`), Android에서 CMake `externalNativeBuild`로 링크한다.

### 메모리·열 관리

- 모델은 `mmap`으로 올려 RSS 급증을 줄인다. iOS는 앱 메모리 경고 시 엔진을 `close`하고 다음 요청에서 지연 로드한다.
- `n_ctx`는 요청 최대 토큰(state + 모든 branch 합)으로 잡는다. v0.1 기본값은 2,048이다.
- 연속 호출 시 기기 온도가 오르면 throttling이 걸린다. 벤치마크는 cold, warm, sustained(60초 연속) 세 조건으로 따로 잰다.

**스파이크에서 먼저 확인할 것**: M0에서 고정한 jev-style GGUF와 llama.cpp로 exact·batched 공유 경로를 개별 prefill과 비교한다.
확률 차이는 모든 질문에서 엄격히 `1e-3` 미만이어야 하며, 실제 공유 토큰 수와 지연도 함께 기록한다.
데스크톱 결과와 iOS warm p50은 별도로 측정한다.

## 공개 API 설계

원칙은 세 가지다. 질문 정의는 타입이 있는 값이고, 답은 사용자 enum으로 돌아오며, 불확실함은 컴파일러가 처리를 강제한다. 목록의 [kojev](https://github.com/ItisNoMatter/kojev)(Choice 답을 사용자 enum으로 반환)와 [discern](https://github.com/doeixd/discern)(`Uncertain` 분기를 반드시 처리하게 하는 Effect 라이브러리)이 좋은 선례다. Dart 3의 sealed class와 패턴 매칭이면 두 가지를 모두 자연스럽게 표현할 수 있다.

### Dart

```dart
enum Team { billing, shipping, returns }

final router = HybridRouter(
  local: await LocalEngine.open(ModelRef.jevStyle08bQ4),
  remote: RemoteBackend(apiKey: env.typesafeKey),   // 선택
  policy: RoutePolicy.localFirst(minConfidence: 0.6),
);

final r = await router.evaluate(
  state: ticket.text,
  questions: {
    'team': Choice.fromEnum(Team.values, 'Which team should handle this?'),
    'urgent': Noul('Does this need urgent human attention?'),
  },
);

switch (r.choice<Team>('team')) {
  case Decided(:final value, :final confidence): assign(value);
  case Uncertain(:final probabilities): queueForReview(probabilities);
}
```

- `r.choice<T>`는 `Decision<T>` sealed class(`Decided` | `Uncertain`)를 반환한다. 판정 기준은 라우터 정책의 threshold다. 원시 `probabilities`는 두 분기 모두에 남긴다.
- `r.meta`에는 `route`, `latencyMs`, `engine`, `escalated`(로컬 후 원격 재질의 여부)를 담는다.
- 원시 JSON 경로(`router.evaluateJson(Map)`)도 열어 둔다. 공식 SDK 요청을 그대로 붙여넣어 테스트하려는 사용자를 위해서다.

### 테스트 지원

`FakeEngine`은 질문 키별로 고정 분포를 돌려주는 결정적 엔진이다. jev-style의 `--fake`와 같은 역할이다. `RecordingBackend`는 실제 응답을 JSONL로 녹화하고 재생한다. 앱 개발자가 네트워크나 모델 없이 위젯 테스트를 돌릴 수 있어야 도입 장벽이 낮아진다.

### React Native (TS)

```ts
const r = await edgeOne.evaluate({
  state: ticket.text,
  questions: {
    team: choice("Which team?", ["billing", "shipping", "returns"] as const),
    urgent: noul("Does this need urgent human attention?"),
  },
});

const team = r.choice("team"); // { kind: 'decided', value: 'billing' | ... } | { kind: 'uncertain', ... }
```

`as const` 튜플에서 옵션 리터럴 유니온을 추론한다. 요청·응답 타입은 Dart와 같은 JSON Schema에서 생성하므로 필드명이 두 언어에서 같다.

### 모델 수명 주기

```dart
final model = await ModelStore.instance.ensure(
  ModelRef.jevStyle08bQ4,
  onProgress: (received, total) => ...,
  requireUnmetered: true,          // Wi-Fi에서만 다운로드
);
```

`ensure`는 다운로드, sha256 검증, manifest 파싱까지 끝낸 뒤 반환한다. 엔진은 검증된 경로만 연다.

## 하이브리드 라우팅과 캘리브레이션

라우터는 요청 단위가 아니라 **질문 단위**로 판단한다. 한 요청의 질문 5개 중 1개만 gate에 걸리면, 그 질문만 원격으로 다시 보내고 결과를 합친다.

&#91;embedded content: HybridRouter 결정 흐름 · 분기 3개\]

처음 분기의 ‘한도·정책’은 옵션 수(v0.1은 26 초과), 토큰 예산 초과, 질문에 `remoteOnly` 태그가 붙은 경우를 걸러낸다. ‘원격 호출 허용’은 앱 정책(`localOnly`), 사용자 동의, 네트워크 상태, 일일 비용 상한을 모두 본다. 원격으로 보내기 직전에 `beforeRemote(state) → state` 훅을 호출해 앱이 개인정보를 마스킹할 수 있게 한다.

### threshold는 데이터로 정한다

기본값 0.6은 출발점일 뿐이다. 로컬 모델의 confidence는 모델·양자화·질문마다 다르게 보정돼 있고, Jev 자체도 알려진 캘리브레이션 문제가 있다. `edge-one-calibrate`는 다음 순서로 threshold를 적합한다.

1. 입력: `/v1/systemone` 요청 형식 JSONL에 질문별 `label`을 붙인 파일. jev-style의 `eval`과 같은 형식을 쓴다.
2. 로컬 엔진(실기기 또는 같은 GGUF를 쓰는 데스크톱 빌드)과 원격 Jev를 각각 돌려 답을 캐시한다.
3. 절반으로 temperature T를 다시 맞추고, 나머지 절반에서 검증한다.
4. 질문별로 ‘허용 오류율 e에서 로컬이 처리하는 비율’이 최대가 되는 threshold를 찾는다. e는 1 / 5 / 10%를 기본으로 보고한다.
5. 출력: `thresholds.json`(질문 키 → threshold, T, 모델 해시). 앱은 이 파일을 에셋으로 번들한다. 모델 해시가 다르면 라우터가 경고를 내고 보수적 기본값으로 돌아간다.

CI에서는 같은 데이터셋으로 회귀 검사를 돌린다. 모델이나 llama.cpp pin을 올렸을 때 자동화율이나 오류율이 정해진 폭 이상 변하면 빌드를 실패시킨다. [jevcal](https://github.com/abhixhek/jevcal)이 원격 Jev에 대해 하는 일을 로컬+원격 쌍에 대해 하는 셈이다.

### 비용 모델

질문당 기대 비용은 로컬 비용(사실상 배터리·지연)에 에스컬레이션 확률 × 원격 비용을 더한 값이다. 하이브리드의 가치는 에스컬레이션 비율이 결정하므로, 벤치마크 리포트의 핵심 지표는 정확도가 아니라 ‘목표 오류율에서의 로컬 처리율’이다. 같은 구조를 원격 모델 사이에서 측정한 독립 실험에서는 0.80 gate 밑을 상위 모델로 넘겨 상위 모델 정확도를 약 4분의 1 비용에 맞춘 결과가 있다([ayautomate](https://www.ayautomate.com/blog/jev-vs-llm-benchmark)). 로컬→Jev에서도 같은 패턴이 나오는지가 이 프로젝트의 가장 중요한 검증 가설이다.

### shadow 모드

도입 초기에는 샘플링된 일부 요청을 로컬과 원격에 모두 보내고 일치율만 기록한다. 앱에는 여전히 한 경로의 답만 쓴다. 원격으로 데이터가 나가므로 동의와 마스킹 훅 적용이 전제다.

## 모델 배포와 패키징

기본 모델은 jev-style v3 Q4\_K\_M(0.53 GB)이다. 이미 GGUF로 배포되고 있고, 라이선스가 Apache-2.0이며, 온도까지 함께 제공되는 유일한 후보다. kev는 방식 B 실험용으로 둔다.

| 후보                                                                    | 백본                       | 모바일용 크기                        | 라이선스                              | 보고된 수치                                  | 용도          |
| ----------------------------------------------------------------------- | -------------------------- | ------------------------------------ | ------------------------------------- | -------------------------------------------- | ------------- |
| [Jev-Style-0.8B-Decision-v3](https://github.com/lawrence3699/jev-style) | Qwen3.5-0.8B fine-tune     | 0.53 GB (Q4\_K\_M), 0.81 GB (Q8\_0)  | Apache-2.0 (가중치·코드)              | Banking77 68.2%, 컨텍스트 25,600 토큰        | **v0.1 기본** |
| [kev-0.5b](https://github.com/jaredpalmer/kev)                          | Qwen2.5-0.5B + LoRA + head | 어댑터 38 MB + 백본 (GGUF 변환 필요) | 코드 Apache-2.0, 백본은 Qwen 라이선스 | in-distribution 평균 정확도 0.799, ECE 0.065 | 방식 B 실험   |
| [Laya](https://github.com/NandhaKishorM/laya)                           | 다국어 결정 모델           | M1에서 확인                          | M1에서 확인                           | jev-style 표에서 v3보다 낮음                 | 비교 기준선   |

두 가지를 유의한다. 첫째, jev-style 저자도 호스팅 Jev가 공개된 모든 세트에서 v3보다 정확하다고 명시한다. 로컬은 대체재가 아니라 1차 필터다. 둘째, kev 수치는 학습 데이터셋의 test split이라 새 워크플로의 성능을 말해주지 않는다.

### 배포 방식

모델은 앱에 번들하지 않고 첫 사용 시 다운로드한다. 앱 크기를 유지하고, 모델을 교체할 때 앱 재배포가 필요 없다. 호스팅은 Hugging Face의 고정 revision을 기본으로 하고, 가용성을 위해 자체 미러(Cloudflare R2 등)를 둔다. URL은 manifest가 정한다.

```json
{
  "id": "jev-style-0.8b-decision-v3",
  "revision": "<hf commit sha>",
  "file": "model-Q4_K_M.gguf",
  "sha256": "...",
  "bytes": 530000000,
  "template": "macjev-render-v1",
  "readout": "verdict",
  "slot_tokens": { "yes": 9542, "no": 874, "verdict_slot": 1411 },
  "temperature": { "choice": 1.0, "noul": 1.0, "score": 1.0 },
  "limits": { "max_options": 26, "max_levels": 10, "n_ctx": 2048 },
  "license": "Apache-2.0",
  "mirrors": ["https://..."]
}
```

`slot_tokens`는 고정한 모델의 readout 설정에서 가져오며, `" yes"`, `" no"`, `" ->"` 문자열이 각각 해당 단일 토큰 id로 인코딩되는지 검증한다.
`temperature` 값은 예시이며 실제 값은 모델 저장소의 readout 설정에서 가져온다.
manifest는 패키지에 포함하고 서명 검증을 거친다.
원격에서 manifest를 받아 그대로 신뢰하면 공급망 공격 경로가 되기 때문이다.

### 다운로드와 캐시

- Range 요청으로 이어받기를 지원한다. iOS는 background `URLSession`, Android는 WorkManager로 처리한다.
- 저장 위치: iOS는 Application Support(백업 제외 플래그), Android는 `filesDir`. 캐시 디렉터리는 OS가 지울 수 있어서 쓰지 않는다.
- 검증: sha256이 일치해야 원자적 rename으로 확정한다. 부분 파일은 `.part`로 둔다.
- 교체: 새 revision을 받아 검증한 뒤 다음 엔진 open에서 전환한다. 이전 파일은 전환 성공 뒤에 지운다.
- 용량 확인: 다운로드 전 여유 공간이 파일 크기의 2배 미만이면 실패로 처리한다.

## 평가·벤치마크 계획

리포트의 한 줄 결론은 이런 형태가 되어야 한다. "목표 오류율 X%에서 로컬이 Y%를 처리하고, 나머지만 Jev로 보내 비용은 Z배, p50 지연은 W ms". 정확도 표 하나로는 이 프로젝트의 가치를 보여줄 수 없다.

**비교군**은 세 가지다. 로컬 단독, 원격 Jev 단독, 하이브리드(threshold 3\~5개 지점)다. 모든 비교군은 같은 요청 JSONL을 쓰고, 원시 응답을 저장해 재현할 수 있게 한다.

| 데이터셋             | 질문 형태                  | 이유                                                                                                           |
| -------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Banking77            | Choice 77지선다            | Jev 공개 수치가 있어 기준선을 잡기 좋다(아래). 26옵션 상한 초과라 계층 Choice 또는 원격 라우팅 경로를 검증한다 |
| KLUE-YNAT            | Choice 7지선다(뉴스 주제)  | 한국어 성능. 국내 사용자 대상 앱에서 쓸 수 있는지 판단 근거                                                    |
| KLUE-NLI             | Choice 3지선다             | 추론형 판단. kev 보고에서도 가장 약했던 유형                                                                   |
| NSMC                 | Noul(긍정 여부)            | 한국어 이진 분류, 대량 샘플                                                                                    |
| 자체 티켓 세트 200건 | Choice + Noul + Score 혼합 | 실제 앱 요청과 같은 모양. 다중 질문 prefix 공유 효과 측정                                                      |

외부 기준점으로 OpenRouter가 Banking77 테스트 3,080건에서 측정한 Jev 1.13 결과를 쓴다. 정확도 81.0%, median 175 ms, 1,000건당 약 $0.11이다([출처](https://openrouter.ai/blog/insights/jev-vs-claude-opus-5-classification/)). jev-style v3의 같은 세트 수치는 68.2%다.

### 지표

- 품질: 정확도, ECE(10 bin), Brier, 오류율 1 / 5 / 10%에서의 로컬 처리율
- 속도: p50 / p95 지연을 cold(엔진 첫 호출), warm, sustained(60초 연속) 세 조건으로 측정. 질문 수 1 / 5 / 20에서 prefix 공유 경로와 개별 prefill 경로를 비교
- 자원: 피크 RSS, 모델 로드 시간, 100회 호출당 배터리 소모(iOS는 Xcode Energy/Instruments, Android는 batterystats)
- 비용: 1,000건당 원격 호출 수와 금액, 에스컬레이션 비율

**기기 매트릭스**(v0.1 최소): iPhone 1대(A15급) + iPhone 1대(최신), Android 중급 1대 + 플래그십 1대. Android 중급기가 병목일 가능성이 높으므로 목표 latency는 중급기 기준으로 정한다.

**공개 원칙**: 하네스, 요청 JSONL, 원시 응답, 기기·빌드 정보를 모두 공개한다. awesome-jev의 Research 섹션에 있는 벤치마크들처럼 한계(샘플 수, 데이터 누수 가능성, 원격 모델 버전)를 리포트에 명시한다.

## 마일스톤 로드맵

혼자 사이드 프로젝트 기준으로 8주 뒤 v0.1을 공개한다. 각 관문을 통과하지 못하면 다음 단계로 넘어가지 않고 범위를 줄인다. 다른 단계보다 M0 관문이 가장 중요하다. 여기서 prefix 공유가 안 되면 다중 질문 성능 주장 자체가 약해진다.

&#91;embedded content: v0.1 로드맵 · 4단계, 관문 3개 (주 단위, 날짜는 시작일에 맞춰 확정)\]

### M0 스파이크 (1주)

- [ ] jev-style v3 Q4\_K\_M를 데스크톱 llama.cpp로 로드하고, jev-style 서버 응답과 확률을 비교해 템플릿·라벨 토큰을 역산한다
- [ ] `seq_cp` 경로와 branch별 개별 prefill 경로의 확률 차를 확인한다 (관문: < 1e-3)
- [ ] 최소 iOS 앱(하드코딩 요청 1개)으로 warm p50을 잰다
- [ ] 관문 불통과 시: 질문별 개별 prefill로 가고, 다중 질문 성능은 v2 과제로 넘긴다

### M1 코어와 Flutter iOS (3주)

- [ ] `edge_one_core` C API, 요청 검증, 렌더러(구분자 이스케이프 포함)
- [ ] JSON Schema → Dart 타입 생성, `Decision<T>` sealed class
- [ ] `hook/build.dart` + ffigen 바인딩, 전용 isolate 워커
- [ ] `ModelStore`(이어받기, sha256, 원자적 확정), `FakeEngine`, `RecordingBackend`
- [ ] 관문: TypeSafe 문서의 예제 요청들이 로컬 엔진에서 스키마 오류 없이 통과

### M2 Android와 라우터 (2주)

- [ ] Android arm64 빌드, 중급기·플래그십 측정
- [ ] `HybridRouter`(질문 단위 에스컬레이션, `beforeRemote` 훅, 비용 상한), `RemoteBackend`
- [ ] `edge-one-calibrate` CLI와 `thresholds.json` 로딩
- [ ] 관문: 중급 Android warm p50이 목표(초안 300 ms) 이내인지 판정. 초과 시 목표를 실측치로 고치고, 리포트에 밝힌다

### M3 벤치마크와 공개 (2주)

- [ ] 백엔드 3종 × 데이터셋 5종 실행, 원시 로그 공개
- [ ] 데모 앱: 고객 문의 분류기(로컬/원격 배지 표시)
- [ ] pub.dev 게시(`edge_one`, `edge_one_flutter`), README에 지원 기기·한계 명시
- [ ] awesome-jev PR, 기술 블로그 글 1편

## 리스크와 법적 고려사항

가장 큰 리스크는 기술이 아니라 포지셔닝이다. 로컬 0.8B 모델 정확도가 Jev보다 확실히 낮다는 점은 이미 알려져 있다. 그래서 이 프로젝트는 "Jev 대체"가 아니라 "Jev 호출을 줄이는 1차 필터"로 설명해야 하고, 그 주장은 벤치마크의 로컬 처리율로 증명해야 한다.

| 리스크                                                 | 영향                     | 대응                                                             |
| ------------------------------------------------------ | ------------------------ | ---------------------------------------------------------------- |
| 백본 구조 때문에 `seq_cp` prefix 공유가 안 되거나 느림 | 다중 질문 속도 이점 상실 | M0 관문에서 판정. 불가 시 개별 prefill로 가고 주장 범위를 줄인다 |
| Android 중급기 지연이 목표 초과                        | 실사용 가치 하락         | 기기 등급별 정책(저사양은 원격 우선), 실측치 공개                |
| 로컬 캘리브레이션이 도메인 밖에서 무너짐               | 잘못된 자동 결정         | 질문별 threshold 적합 필수화, 기본값은 보수적으로, shadow 모드   |
| llama.cpp API 변경                                     | 빌드 깨짐                | submodule pin, 올릴 때 CI 회귀 검사                              |
| 0.5 GB 다운로드에 대한 사용자 거부감                   | 도입 저하                | 선택적 기능으로 설계, Wi-Fi 전용 옵션, 모델 없을 때 원격 폴백    |
| 생태계 변동(Jev 가격·API 변경, 더 나은 오픈 모델 등장) | 전제 변화                | 스키마 기준 설계, 모델은 manifest로 교체                         |

### 법적 체크리스트

- 개인정보 국외 이전: 원격 Jev로 사용자 텍스트를 보내면 개인정보보호법상 국외 이전 고지·동의 대상이 될 수 있다. 라이브러리는 기본값을 `localOnly`로 두고, 원격 사용 시 앱 개발자가 고지 의무를 진다는 점을 README에 명시한다.
- 모델 라이선스: jev-style 가중치는 Apache-2.0이므로 NOTICE 파일을 앱 오픈소스 고지에 포함해야 한다. kev는 코드와 백본(Qwen 라이선스)의 조건을 따로 확인한다.
- 상표: 패키지명과 설명에 "Jev"나 "TypeSafe"를 제품명처럼 쓰지 않는다. "System One 호환"처럼 스키마 호환성만 표현하고, 비제휴 문구를 둔다. jev-style과 kev도 같은 방식으로 표기한다.
- 원격 약관: TypeSafe 응답을 로컬 모델 학습(증류)에 쓰려면 이용약관이 이를 허용하는지 먼저 확인한다. v0.1은 원격 응답을 평가에만 쓰고 학습에는 쓰지 않는다.
- 자동 결정: 이 런타임으로 사용자에게 불이익을 주는 결정(계정 제재 등)을 자동화할 경우, 사람이 검토하는 경로를 앱 쪽에 두도록 문서에서 권고한다.

이 체크리스트는 법률 자문이 아니다. 상용 앱에 원격 경로를 켜기 전에는 전문가 검토를 받는 것이 안전하다.

## 커리어 산출물

포트폴리오의 중심은 패키지가 아니라 벤치마크 리포트다. 패키지는 "만들 수 있다"를 보여주지만, 리포트는 "측정하고 판단할 수 있다"를 보여준다. 채용 담당자와 기술 리더가 실제로 읽는 쪽은 후자다.

| 산출물                                    | 시점    | 보여주는 역량                                                                                     |
| ----------------------------------------- | ------- | ------------------------------------------------------------------------------------------------- |
| `edge_one` / `edge_one_flutter` (pub.dev) | M3      | Dart 빌드 훅, FFI, C++ 코어 설계, 패키지 운영                                                     |
| `react-native-edge-one` (npm)             | M4      | New Architecture C++ TurboModule. react-native-step-counter와 함께 양 플랫폼 네이티브 브리지 이력 |
| 벤치마크 리포트 + 원시 데이터             | M3      | 온디바이스 AI 성능 측정, 캘리브레이션, 비용 분석                                                  |
| 기술 블로그(한국어·영어 각 1편)           | M3      | 설계 결정 설명: 왜 llama.cpp인지, 왜 KV prefix 공유인지, 왜 질문 단위 라우팅인지                  |
| 컨퍼런스·밋업 발표 제안                   | M3 이후 | "모바일에서 결정 모델 돌리기: 로컬 우선, 원격 폴백"                                               |

**이력서 한 줄 초안**: "iOS·Android에서 System One 호환 결정 모델을 로컬로 실행하는 오픈소스 런타임(Flutter·RN)을 설계·배포. 확신도 기반 하이브리드 라우팅으로 목표 오류율 X%에서 원격 호출 Y% 절감(공개 벤치마크)." X, Y는 M3 실측치로 채운다.

**공개 타이밍**: v0.1 전이라도 M0 스파이크 결과("0.8B 결정 모델, iPhone에서 N ms")는 짧은 글로 먼저 공개할 가치가 있다. Jev 생태계는 공개된 지 일주일이라 초기 기록이 눈에 잘 띈다. 다만 수치는 측정 조건과 함께만 쓴다.

## 출처

- [TypeSafe API reference](https://docs.typesafe.ai/api.md) · [Confidence](https://docs.typesafe.ai/confidence.md)
- [awesome-jev](https://github.com/AnotiaWang/awesome-jev)
- [jev-style](https://github.com/lawrence3699/jev-style) · [kev](https://github.com/jaredpalmer/kev) · [Laya](https://github.com/NandhaKishorM/laya)
- [kojev](https://github.com/ItisNoMatter/kojev) · [discern](https://github.com/doeixd/discern) · [jevcal](https://github.com/abhixhek/jevcal)
- [Announcing Dart 3.10 (build hooks stable)](https://blog.dart.dev/announcing-dart-3-10-ea8b952b6088) · [Dart hooks 문서](https://dart.dev/tools/hooks)
- [llama.cpp PR #17579 (`llama_memory_seq_cp` 논의)](https://github.com/ggml-org/llama.cpp/pull/17579)
- [OpenRouter: Jev vs Claude Opus 5 on Banking77](https://openrouter.ai/blog/insights/jev-vs-claude-opus-5-classification/)
- [AY Automate: Jev vs four LLMs](https://www.ayautomate.com/blog/jev-vs-llm-benchmark)
