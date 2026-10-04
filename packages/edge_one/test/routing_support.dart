import 'package:edge_one/edge_one.dart';
import 'package:edge_one/testing.dart';

final class CapturingBackend implements SystemOneBackend {
  CapturingBackend({SystemOneBackend? backend})
    : backend = backend ?? FakeEngine();

  final SystemOneBackend backend;
  final requests = <SystemOneRequest>[];

  @override
  Future<SystemOneResponse> evaluate(SystemOneRequest request) async {
    requests.add(request);
    return backend.evaluate(request);
  }
}

SystemOneRequest routingRequest({Map<String, SystemOneQuestion>? questions}) =>
    SystemOneRequest(
      model: 'synthetic-model',
      state: {
        'contact': {'email': 'synthetic@example.invalid'},
      },
      questions:
          questions ??
          {
            'topic': ChoiceQuestion(
              instructions: {'private': 'synthetic instruction'},
              criteria: {
                'a': {'private': 'synthetic criterion'},
                'b': 'other',
              },
            ),
          },
    );

Future<RemoteTransportResponse> fakeRemote(Map<String, Object?> json) async {
  final request = SystemOneJson.decodeRequest(json);
  final response = await FakeEngine().evaluate(request);
  return RemoteTransportResponse(
    statusCode: 200,
    body: SystemOneJson.encodeResponse(response),
  );
}

RemotePolicy allowedPolicy({
  bool localOnly = false,
  bool Function()? hasConsent,
  bool Function()? isNetworkAvailable,
  BeforeRemote? beforeRemote,
  RemoteBudget? budget,
  int Function(SystemOneRequest)? estimateCost,
}) => RemotePolicy(
  localOnly: localOnly,
  hasConsent: hasConsent ?? () => true,
  isNetworkAvailable: isNetworkAvailable ?? () => true,
  beforeRemote: beforeRemote ?? (request) => request,
  budget: budget ?? RemoteBudget(dailyLimitMicrocredits: 100),
  estimateCost: estimateCost ?? (_) => 1,
);
