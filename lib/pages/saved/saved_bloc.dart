import 'dart:async';

import 'package:find_room/bloc/bloc_provider.dart';
import 'package:find_room/data/rooms/firestore_room_repository.dart';
import 'package:find_room/models/room_entity.dart';
import 'package:find_room/pages/saved/saved_state.dart';
import 'package:find_room/user_bloc/user_bloc.dart';
import 'package:find_room/user_bloc/user_login_state.dart';
import 'package:intl/intl.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';

const _kInitialSavedListState = SavedListState(
  error: null,
  isLoading: true,
  roomItems: <RoomItem>[],
);

class SavedBloc implements BaseBloc {
  ///
  /// Sinks
  ///
  final Sink<String> removeFromSaved;

  ///
  /// Streams
  ///
  final ValueObservable<SavedListState> savedListState$;
  final Stream<SavedMessage> removeMessage$;

  ///
  /// Clean up
  ///
  final void Function() _dispose;

  SavedBloc._(
    this.removeFromSaved,
    this.savedListState$,
    this._dispose,
    this.removeMessage$,
  );

  factory SavedBloc({
    @required UserBloc userBloc,
    @required FirestoreRoomRepository roomRepository,
    @required NumberFormat priceFormat,
  }) {
    assert(userBloc != null, 'userBloc cannot be null');
    assert(roomRepository != null, 'roomRepository cannot be null');
    assert(priceFormat != null, 'priceFormat cannot be null');

    final removeFromSaved = PublishSubject<String>(sync: true);

    final savedListState$ = _getSavedList(
      userBloc,
      roomRepository,
      priceFormat,
    );
    final removeMessage$ = _getRemovedMessage(
      removeFromSaved,
      userBloc,
      roomRepository,
    );

    final subscriptions = <StreamSubscription>[
      savedListState$.connect(),
      removeMessage$.connect(),
    ];

    return SavedBloc._(
      removeFromSaved,
      savedListState$,
      () {
        removeFromSaved.close();
        subscriptions.forEach((s) => s.cancel());
      },
      removeMessage$,
    );
  }

  @override
  void dispose() => _dispose();

  static Observable<SavedListState> _toState(
    UserLoginState loginState,
    FirestoreRoomRepository roomRepository,
    NumberFormat priceFormat,
  ) {
    if (loginState is NotLogin) {
      return Observable.just(
        _kInitialSavedListState.copyWith(
          error: NotLoginError(),
          isLoading: false,
        ),
      );
    }
    if (loginState is UserLogin) {
      return Observable(roomRepository.savedList(uid: loginState.uid))
          .map((entities) {
            return _entitiesToRoomItems(
              entities,
              priceFormat,
              loginState.uid,
            );
          })
          .map((roomItems) {
            return _kInitialSavedListState.copyWith(
              roomItems: roomItems,
              isLoading: false,
            );
          })
          .startWith(_kInitialSavedListState)
          .onErrorReturnWith((e) {
            return _kInitialSavedListState.copyWith(
              error: e,
              isLoading: false,
            );
          });
    }
    return Observable.just(
      _kInitialSavedListState.copyWith(
        error: "Don't know loginState=$loginState",
        isLoading: false,
      ),
    );
  }

  static List<RoomItem> _entitiesToRoomItems(
    List<RoomEntity> entities,
    NumberFormat priceFormat,
    String uid,
  ) {
    return entities.map((entity) {
      return RoomItem(
        id: entity.id,
        title: entity.title,
        price: priceFormat.format(entity.price),
        address: entity.address,
        districtName: entity.districtName,
        image: entity.images.isNotEmpty ? entity.images.first : null,
        savedTime: entity.userIdsSaved[uid].toDate(),
      );
    }).toList();
  }

  static ValueConnectableObservable<SavedListState> _getSavedList(
    UserBloc userBloc,
    FirestoreRoomRepository roomRepository,
    NumberFormat priceFormat,
  ) {
    return userBloc.userLoginState$
        .switchMap((loginState) {
          return _toState(
            loginState,
            roomRepository,
            priceFormat,
          );
        })
        .distinct()
        .publishValue(seedValue: _kInitialSavedListState);
  }

  static ConnectableObservable<RemovedSaveRoomMessage> _getRemovedMessage(
    Observable<String> removeFromSaved,
    UserBloc userBloc,
    FirestoreRoomRepository roomRepository,
  ) {
    return removeFromSaved.flatMap((roomId) {
      var loginState = userBloc.userLoginState$.value;
      if (loginState is NotLogin) {
        return Observable.just(RemovedSaveRoomMessageError(NotLoginError()));
      }

      if (loginState is UserLogin) {
        return Observable.fromFuture(roomRepository.addOrRemoveSavedRoom(
                roomId: roomId, userId: loginState.uid))
            .map((result) => RemovedSaveRoomMessageSuccess(result['title']))
            .cast<RemovedSaveRoomMessage>()
            .onErrorReturnWith((e) => RemovedSaveRoomMessageError(e));
      }
    }).publish();
  }
}
