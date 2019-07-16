import 'dart:async';
import 'dart:io';

import 'package:distinct_value_connectable_observable/distinct_value_connectable_observable.dart';
import 'package:find_room/bloc/bloc_provider.dart';
import 'package:find_room/data/user/firebase_user_repository.dart';
import 'package:find_room/pages/user_profile/update_user_info/update_user_info_state.dart';
import 'package:find_room/user_bloc/user_bloc.dart';
import 'package:find_room/user_bloc/user_login_state.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';
import 'package:path/path.dart' as path;

// ignore_for_file: close_sinks

class UpdateUserInfoBloc implements BaseBloc {
  ///
  /// Output [Stream]s
  ///
  final Stream<FullNameError> fullNameError$;
  final Stream<PhoneNumberError> phoneNumberError$;
  final Stream<AddressError> addressError$;
  final Stream<UpdateUserInfoMessage> message$;
  final ValueObservable<bool> isLoading$;
  final ValueObservable<File> avatar$;

  ///
  /// Input [Function]s
  ///
  final void Function() submitChanges;
  final void Function(String) fullNameChanged;
  final void Function(String) addressChanged;
  final void Function(String) phoneNumberChanged;
  final void Function(File) avatarChanged;

  ///
  /// Clean up resources
  ///
  final void Function() _dispose;

  UpdateUserInfoBloc._(
    this._dispose, {
    @required this.fullNameError$,
    @required this.message$,
    @required this.isLoading$,
    @required this.submitChanges,
    @required this.fullNameChanged,
    @required this.avatar$,
    @required this.avatarChanged,
    @required this.phoneNumberError$,
    @required this.addressError$,
    @required this.addressChanged,
    @required this.phoneNumberChanged,
  });

  @override
  void dispose() => _dispose();

  factory UpdateUserInfoBloc({
    @required String uid,
    @required FirebaseUserRepository userRepo,
    @required UserBloc userBloc,
  }) {
    ///
    /// Asserts
    ///
    assert(uid != null, 'uid cannot be null');
    assert(userRepo != null, 'userRepo cannot be null');
    assert(userBloc != null, 'userBloc cannot be null');
    assert(() {
      final loginState = userBloc.loginState$.value;
      if (loginState == null) return false;
      if (loginState is Unauthenticated) return false;
      if (loginState is LoggedInUser) return loginState.uid == uid;
    }(), 'User is not logged in or invalid user id');

    ///
    /// Controllers
    ///
    final submitController = PublishSubject<void>();
    final fullNameController = BehaviorSubject.seeded('');
    final addressController = BehaviorSubject.seeded('');
    final phoneNumberController = BehaviorSubject.seeded('');
    final isLoadingController = BehaviorSubject.seeded(false);
    final avatarSubject = PublishSubject<File>();

    ///
    /// Errors streams
    ///
    final fullNameError$ = fullNameController.map((name) {
      if (name == null || name.length < 3) {
        return const LengthOfFullNameLessThen3CharactersError();
      }
      return null;
    }).share();

    final addressError$ = addressController.map(
      (address) {
        if (address == null || address.isEmpty) {
          return const EmptyAddressError();
        }
        return null;
      },
    ).share();

    final phoneNumberError$ = phoneNumberController.map(
      (phoneNumber) {
        const regex = r'^[+]*[(]{0,1}[0-9]{1,4}[)]{0,1}[-\s\./0-9]*$';
        if (!RegExp(regex, caseSensitive: false).hasMatch(phoneNumber)) {
          return const InvalidPhoneNumberError();
        }
        return null;
      },
    ).share();

    ///
    /// Combine error streams with submit stream
    ///

    final isValid$ = Observable.combineLatest(
      [
        fullNameError$,
        addressError$,
        phoneNumberError$,
      ],
      (allErrors) => allErrors.every((e) => e == null),
    );

    final validSubmit$ = submitController
        .withLatestFrom(
          isValid$,
          (_, isValid) => isValid,
        )
        .share();

    ///
    /// Transform submit stream
    ///

    final avatar$ = publishValueDistinct<File>(
      avatarSubject
          .doOnData((file) => print('[UPDATE_USER_INFO_BLOC] file=$file')),
      equals: (prev, next) => path.equals(prev?.path ?? '', next?.path ?? ''),
    );

    final message$ = Observable.merge([
      validSubmit$
          .where((isValid) => !isValid)
          .map((_) => const UpdateUserInfoMessage.invalidInfomation()),
      validSubmit$.where((isValid) => isValid).exhaustMap(
            (_) => _performUpdateInfo(
                  address: addressController.value,
                  avatar: avatar$.value,
                  fullName: fullNameController.value,
                  isLoadingSink: isLoadingController,
                  phoneNumber: phoneNumberController.value,
                  userRepo: userRepo,
                ),
          ),
    ]).publish();

    ///
    /// Subscriptions & controllers
    ///
    final subscriptions = <StreamSubscription>[
      avatar$
          .listen((file) => print('[UPDATE_USER_INFO_BLOC] final file=$file')),
      message$.listen(
          (message) => print('[UPDATE_USER_INFO_BLOC] message=$message')),
      message$.connect(),
      avatar$.connect(),
    ];
    final controllers = <StreamController>{
      submitController,
      isLoadingController,
      avatarSubject,
      fullNameController,
      addressController,
      phoneNumberController,
    };

    return UpdateUserInfoBloc._(
      () async {
        await Future.wait(subscriptions.map((s) => s.cancel()));
        await Future.wait(controllers.map((c) => c.close()));
        print('[UPDATE_USER_INFO_BLOC] disposed');
      },

      ///
      /// Inputs
      ///
      avatarChanged: avatarSubject.add,
      fullNameChanged: fullNameController.add,
      submitChanges: () => submitController.add(null),
      addressChanged: addressController.add,
      phoneNumberChanged: phoneNumberController.add,

      ///
      /// Outputs
      ///
      fullNameError$: fullNameError$,
      isLoading$: isLoadingController,
      message$: message$,
      avatar$: avatar$,
      addressError$: addressError$,
      phoneNumberError$: null,
    );
  }

  static Stream<UpdateUserInfoMessage> _performUpdateInfo({
    @required FirebaseUserRepository userRepo,
    @required String fullName,
    @required String address,
    @required String phoneNumber,
    @required File avatar,
    @required Sink<bool> isLoadingSink,
  }) async* {
    try {
      isLoadingSink.add(true);
      await userRepo.updateUserInfo(
        fullName: fullName,
        avatar: avatar,
        address: address,
        phoneNumber: phoneNumber,
      );
      yield const UpdateUserInfoMessage.updateSuccess();
    } catch (e) {
      yield UpdateUserInfoMessage.updateFailure(getError(e));
    } finally {
      isLoadingSink.add(false);
    }
  }

  static UpdateUserInfoError getError(e) {
    //TODO:
  }
}
