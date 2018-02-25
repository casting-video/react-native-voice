#import "Voice.h"
#import <React/RCTLog.h>
#import <UIKit/UIKit.h>
#import <React/RCTUtils.h>
#import <React/RCTEventEmitter.h>
#import <Speech/Speech.h>

@interface Voice () <SFSpeechRecognizerDelegate>

@property (nonatomic) SFSpeechRecognizer* speechRecognizer;
@property (nonatomic) SFSpeechAudioBufferRecognitionRequest* recognitionRequest;
@property (nonatomic) AVAudioEngine* audioEngine;
@property (nonatomic) SFSpeechRecognitionTask* recognitionTask;

@end

@implementation Voice
{
}

- (void) setupAndStartRecognizing:(NSString*)localeStr {
    [self teardown];

    @try {
        // Setup audioEngine
        self.audioEngine = [[AVAudioEngine alloc] init];

        AVAudioInputNode* inputNode = self.audioEngine.inputNode;
        if (inputNode == nil) {
            @throw [NSException
                    exceptionWithName:@"E_SPEECH"
                    reason:@"Audio engine has no input node"
                    userInfo:nil];
        }

        AVAudioFormat* recordingFormat = [inputNode outputFormatForBus:0];
        if (recordingFormat.sampleRate == 0 || recordingFormat.channelCount == 0) {
            @throw [NSException
                    exceptionWithName:@"E_SPEECH"
                    reason:@"Could not intiialize recording input"
                    userInfo:nil];
        }

        [inputNode installTapOnBus:0 bufferSize:1024 format:recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
            if (self.recognitionRequest != nil) {
                [self.recognitionRequest appendAudioPCMBuffer:buffer];
            }
        }];

        [self.audioEngine prepare];

        // Setup speechRecognizer
        NSLocale* locale = nil;
        if ([localeStr length] > 0) {
            locale = [NSLocale localeWithLocaleIdentifier:localeStr];
        }

        if (locale) {
            self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
        } else {
            self.speechRecognizer = [[SFSpeechRecognizer alloc] init];
        }

        self.speechRecognizer.delegate = self;

        // Setup recognitionRequest
        self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];

        if (self.recognitionRequest == nil) {
            @throw [NSException
                    exceptionWithName:@"E_SPEECH"
                    reason:@"Unable to created a SFSpeechAudioBufferRecognitionRequest object"
                    userInfo:nil];
        }

        // Configure request so that results are returned before audio recording is finished
        self.recognitionRequest.shouldReportPartialResults = YES;

        // Dictation hint
        self.recognitionRequest.taskHint = SFSpeechRecognitionTaskHintDictation;

        // A recognition task represents a speech recognition session.
        // We keep a reference to the task so that it can be cancelled.
        self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
            if (error != nil) {
                NSString *errorMessage = [NSString stringWithFormat:@"%ld/%@", error.code, [error localizedDescription]];
                [self sendResult:RCTMakeError(errorMessage, nil, nil) :nil :nil :nil];
                [self teardown];
                return;
            }

            BOOL isFinal = result.isFinal;
            if (result != nil) {
                NSMutableArray* transcriptionDics = [NSMutableArray new];
                for (SFTranscription* transcription in result.transcriptions) {
                    [transcriptionDics addObject:transcription.formattedString];
                }
                [self sendResult:nil:result.bestTranscription.formattedString :transcriptionDics :@(isFinal)];
            }

            if (isFinal == YES) {
                if (self.recognitionTask.isCancelled || self.recognitionTask.isFinishing){
                    [self sendEventWithName:@"onSpeechEnd" body:@{@"error": @false}];
                }
                [self teardown];
            }
        }];

        // Start the recording
        NSError *error = nil;
        [self.audioEngine startAndReturnError:&error];
        if (error != nil) {
            @throw [NSException
                    exceptionWithName:@"E_SPEECH"
                    reason:[@"Audio engine start failed" stringByAppendingString:error.localizedDescription]
                    userInfo:nil];
        }

        // Notify the app
        [self sendEventWithName:@"onSpeechStart" body:@true];
    }

    @catch (NSException *exception) {
        [self sendResult:RCTMakeError([@"Exception: " stringByAppendingString:exception.reason], nil, nil) :nil :nil :nil];
        [self teardown];
    }
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[
        @"onSpeechResults",
        @"onSpeechStart",
        @"onSpeechPartialResults",
        @"onSpeechError",
        @"onSpeechEnd",
        @"onSpeechRecognized",
        @"onSpeechVolumeChanged"
    ];
}

- (void) sendResult:(NSDictionary*)error :(NSString*)bestTranscription :(NSArray*)transcriptions :(NSNumber*)isFinal {
    if (error != nil) {
        [self sendEventWithName:@"onSpeechError" body:@{@"error": error}];
    }
    if (bestTranscription != nil) {
        [self sendEventWithName:@"onSpeechResults" body:@{@"value":@[bestTranscription]} ];
    }
    if (transcriptions != nil) {
        [self sendEventWithName:@"onSpeechPartialResults" body:@{@"value":transcriptions} ];
    }
    if (isFinal != nil) {
        [self sendEventWithName:@"onSpeechRecognized" body: @{@"isFinal": isFinal}];
    }
}

- (void) teardown {
    [self.recognitionTask cancel];
    self.recognitionTask = nil;

    if (self.audioEngine != nil) {
        if (self.audioEngine.isRunning) {
            [self.audioEngine stop];
            [self.recognitionRequest endAudio];
            [self.audioEngine.inputNode removeTapOnBus:0];
        }
        self.audioEngine = nil;
    }

    self.recognitionRequest = nil;
}

// Called when the availability of the given recognizer changes
- (void)speechRecognizer:(SFSpeechRecognizer *)speechRecognizer availabilityDidChange:(BOOL)available {
    if (available == false) {
        [self sendResult:RCTMakeError(@"Speech recognition is not available now", nil, nil) :nil :nil :nil];
    }
}

RCT_EXPORT_METHOD(stopSpeech:(RCTResponseSenderBlock)callback)
{
    [self.recognitionTask finish];
    callback(@[@false]);
}


RCT_EXPORT_METHOD(cancelSpeech:(RCTResponseSenderBlock)callback) {
    [self.recognitionTask cancel];
    callback(@[@false]);
}

RCT_EXPORT_METHOD(destroySpeech:(RCTResponseSenderBlock)callback) {
    [self teardown];
    callback(@[@false]);
}

RCT_EXPORT_METHOD(isSpeechAvailable:(RCTResponseSenderBlock)callback) {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        switch (status) {
            case SFSpeechRecognizerAuthorizationStatusAuthorized:
                callback(@[@true]);
                break;
            default:
                callback(@[@false]);
        }
    }];
}
RCT_EXPORT_METHOD(isRecognizing:(RCTResponseSenderBlock)callback) {
    if (self.recognitionTask != nil){
        switch (self.recognitionTask.state) {
            case SFSpeechRecognitionTaskStateRunning:
                callback(@[@true]);
                break;
            default:
                callback(@[@false]);
        }
    }
    else {
        callback(@[@false]);
    }
}

RCT_EXPORT_METHOD(startSpeech:(NSString*)localeStr callback:(RCTResponseSenderBlock)callback) {
    if (self.recognitionTask != nil) {
        [self sendResult:RCTMakeError(@"Speech recognition already started!", nil, nil) :nil :nil :nil];
        callback(@[@false]);
        return;
    }

    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        switch (status) {
            case SFSpeechRecognizerAuthorizationStatusNotDetermined:
                [self sendResult:RCTMakeError(@"Speech recognition not yet authorized", nil, nil) :nil :nil :nil];
                break;
            case SFSpeechRecognizerAuthorizationStatusDenied:
                [self sendResult:RCTMakeError(@"User denied access to speech recognition", nil, nil) :nil :nil :nil];
                break;
            case SFSpeechRecognizerAuthorizationStatusRestricted:
                [self sendResult:RCTMakeError(@"Speech recognition restricted on this device", nil, nil) :nil :nil :nil];
                break;
            case SFSpeechRecognizerAuthorizationStatusAuthorized:
                [self setupAndStartRecognizing:localeStr];
                break;
        }
    }];
    callback(@[@false]);
}


- (dispatch_queue_t)methodQueue {
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()



@end
