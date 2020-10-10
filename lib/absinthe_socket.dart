library absinthe_socket;

import 'package:phoenix_wings/phoenix_wings.dart';

/// An Absinthe Socket
class AbsintheSocket {
  AbsintheSocket(
    this.endpoint, {
    this.socketOptions,
  }) {
    _subscriptionHandler = NotifierPushHandler<Map>(
        onError: _onError,
        onTimeout: _onTimeout,
        onSucceed: _onSubscriptionSucceed);

    _unsubscriptionHandler = NotifierPushHandler<Map>(
        onError: _onError,
        onTimeout: _onTimeout,
        onSucceed: _onUnsubscriptionSucceed);

    _phoenixSocket = PhoenixSocket(
      endpoint,
      socketOptions: PhoenixSocketOptions(
        params: (socketOptions ?? AbsintheSocketOptions()).params
          ..addAll(
            {
              'vsn': '2.0.0',
            },
          ),
      ),
    );

    _connect();
  }

  final AbsintheSocketOptions socketOptions;
  final List<Notifier<Map>> _notifiers = [];
  final List<Notifier<Map>> _queuedPushes = [];

  String endpoint;

  PhoenixChannel _absintheChannel;
  PhoenixSocket _phoenixSocket;
  NotifierPushHandler<Map> _subscriptionHandler;
  NotifierPushHandler<Map> _unsubscriptionHandler;

  bool _socketReopening;

  dynamic _onError(
    Map response,
  ) {
    print('onError');
    print(response.toString());
  }

  dynamic Function(Map) _onSubscriptionSucceed(
    Notifier<Map> notifier,
  ) {
    return (response) {
      print('response');
      print(response.toString());

      notifier.subscriptionId = response['subscriptionId'] as String;
    };
  }

  dynamic Function(Map) _onUnsubscriptionSucceed(
    Notifier notifier,
  ) {
    return (Map response) {
      print('unsubscription response');
      // print(response.toString());

      notifier.cancel();
      _notifiers.remove(notifier);
    };
  }

  static void _onTimeout(
    Map response,
  ) {
    print('onTimeout');
  }

  void _connect() async {
    await _phoenixSocket.connect();

    _phoenixSocket.onOpen(_onSocketOpen);
    _phoenixSocket.onClose(_onSocketClose);
    _phoenixSocket.onMessage(_onSocketMessage);
    _phoenixSocket.onError(_onSocketError);

    _absintheChannel = _phoenixSocket.channel('__absinthe__:control');

    _absintheChannel.join().receive('ok', _sendQueuedPushes);
  }

  void disconnect() {
    _phoenixSocket.disconnect();
  }

  void _sendQueuedPushes(
    Map response,
  ) {
    _queuedPushes
      ..forEach(_pushRequest)
      ..clear();
  }

  void cancel(
    Notifier<Map> notifier,
  ) {
    unsubscribe(notifier);
  }

  void unsubscribe(
    Notifier<Map> notifier,
  ) {
    _handlePush(
        _absintheChannel.push(
            event: 'unsubscribe',
            payload: {'subscriptionId': notifier.subscriptionId} as Map),
        _createPushHandler(_unsubscriptionHandler, notifier));
  }

  Notifier send(GqlRequest request) {
    final notifier = Notifier<Map>(request: request);

    _notifiers.add(notifier);
    _pushRequest(notifier);

    return notifier;
  }

  // It looks like `_onSocketOpen()` is only called when reopening the
  // connection but that might change in the future and an additional check
  // doesn't hurt.
  void _onSocketOpen() {
    if (_socketReopening) {
      _notifiers.forEach((notifier) {
        _handlePush(
          _absintheChannel.push(
            event: 'doc',
            payload: {'query': notifier.request.operation} as Map,
          ),
          _createPushHandler(_subscriptionHandler, notifier),
        );
      });
    }
  }

  void _onSocketClose(dynamic result) {
    _socketReopening = true;
  }

  void _onSocketMessage(PhoenixMessage message) {
    final subscriptionId = message.topic;

    _notifiers
        .where(
          (notifier) => notifier.subscriptionId == subscriptionId,
        )
        .forEach(
          (notifier) => notifier.notify(
            message.payload['result'] as Map,
          ),
        );
  }

  void _onSocketError(dynamic error) {
    print('Socket Error: $error');
  }

  void _pushRequest(Notifier<Map> notifier) {
    if (_absintheChannel == null) {
      _queuedPushes.add(notifier);
    } else {
      _handlePush(
        _absintheChannel.push(
          event: 'doc',
          payload: {'query': notifier.request.operation} as Map,
        ),
        _createPushHandler(_subscriptionHandler, notifier),
      );
    }
  }

  void _handlePush(PhoenixPush push, PushHandler<Map> handler) {
    push
        .receive('ok', handler.onSucceed)
        .receive('error', handler.onError)
        .receive('timeout', handler.onTimeout);
  }

  PushHandler<Map> _createPushHandler(
    NotifierPushHandler<Map> notifierPushHandler,
    Notifier<Map> notifier,
  ) {
    return _createEventHandler(notifier, notifierPushHandler);
  }

  PushHandler<Map> _createEventHandler(
    Notifier<Map> notifier,
    NotifierPushHandler<Map> notifierPushHandler,
  ) {
    return PushHandler<Map>(
        onError: notifierPushHandler.onError,
        onSucceed: notifierPushHandler.onSucceed(notifier),
        onTimeout: notifierPushHandler.onTimeout);
  }
}

class AbsintheSocketOptions {
  AbsintheSocketOptions({this.params});

  final Map<String, String> params;
}

class Notifier<Result> {
  Notifier({this.request});

  final List<Observer<Result>> observers = [];

  GqlRequest request;
  String subscriptionId;

  void observe(Observer<Result> observer) {
    observers.add(observer);
  }

  void notify(Map result) {
    observers.forEach((Observer observer) => observer.onResult(result));
  }

  void cancel() {
    observers.forEach((Observer observer) => observer.onCancel());
  }
}

class Observer<Result> {
  Observer({
    this.onAbort,
    this.onCancel,
    this.onError,
    this.onStart,
    this.onResult,
  });

  final Function onAbort;
  final Function onCancel;
  final Function onError;
  final Function onStart;
  final Function onResult;
}

class GqlRequest {
  GqlRequest({this.operation});

  final String operation;
}

class NotifierPushHandler<Response> {
  NotifierPushHandler({
    this.onError,
    this.onSucceed,
    this.onTimeout,
  });

  final dynamic Function(Response) onError;
  final dynamic Function(Response) Function(Notifier<Response>) onSucceed;
  final dynamic Function(Response) onTimeout;
}

class PushHandler<Response> {
  PushHandler({
    this.onError,
    this.onSucceed,
    this.onTimeout,
  });

  final dynamic Function(Response) onError;
  final dynamic Function(Response) onSucceed;
  final dynamic Function(Response) onTimeout;
}
