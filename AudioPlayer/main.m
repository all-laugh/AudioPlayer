//
//  main.m
//  AudioPlayer
//
//  Created by Xiao Quan on 12/15/21.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#define    kPlaybackFileLocation    CFSTR("/Users/xiaoquan/Downloads/jigsaw.mp3")
#define    kNumberPlaybackBuffers   3

// User data struct
typedef struct Player {
    AudioFileID                     playbackFile;
    SInt64                          packetPosition;
    UInt32                          numPacketsToRead;
    AudioStreamBasicDescription     *packetDescriptions;
    Boolean                         isDone;
} Player;

// Utils

static void CheckError(OSStatus error, const char *operation) {
    if (error == noErr) return;
    
    char errorString[20];
    // Is error a four char code?
    *(UInt32 *) (errorString + 1) = CFSwapInt32BigToHost(error);
    if (isprint(errorString[1]) &&
        isprint(errorString[2]) &&
        isprint(errorString[3]) &&
        isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    } else {
        // Format error as an integer
        sprintf(errorString, "%d", (int) error);
    }
    fprintf(stderr, "Error: %s (%s) \n", operation, errorString);
    
    exit(1);
}

static void CopyEncoderCookieToQueue(AudioFileID file,
                                     AudioQueueRef queue) {
    UInt32 propertySize;
    OSStatus result = AudioFileGetPropertyInfo(file,
                                               kAudioFilePropertyMagicCookieData,
                                               &propertySize,
                                               NULL);
    if (result == noErr && propertySize > 0) {
        Byte* magicCookie = (UInt8*) malloc(sizeof(UInt8) * propertySize);
        CheckError(AudioFileGetProperty(file,
                                        kAudioFilePropertyMagicCookieData,
                                        &propertySize,
                                        magicCookie),
                   "Error getting magic cookie from file");
        CheckError(AudioQueueSetProperty(queue,
                                         kAudioQueueProperty_MagicCookie,
                                         magicCookie,
                                         propertySize),
                   "Error setting magic cookie to Audio Queue");
        free(magicCookie);
    }
}

static void CalculateBytesForTime(AudioFileID file,
                                  AudioStreamBasicDescription inDesc,
                                  Float64 inSeconds,
                                  UInt32 *outBufferSize,
                                  UInt32 *outNumPackets) {
    UInt32 maxPacketSize;
    UInt32 propSize = sizeof(maxPacketSize);
    CheckError(AudioFileGetProperty(file,
                                    kAudioFilePropertyPacketSizeUpperBound,
                                    &propSize,
                                    &maxPacketSize),
               "AudioFile failed getting max packet size");
    
    static const int maxBufferSize = 0x10000;
    static const int minBufferSize = 0x4000;
    
    if (inDesc.mFramesPerPacket) {
        Float64 numPacketsForTime = inDesc.mSampleRate /
                                    inDesc.mFramesPerPacket * inSeconds;
        *outBufferSize = numPacketsForTime * maxPacketSize;
    } else {
        *outBufferSize = maxBufferSize > maxPacketSize ?
                            maxBufferSize : maxPacketSize;
    }
    
    if (*outBufferSize > maxBufferSize &&
        *outBufferSize > maxPacketSize) {
        *outBufferSize = maxBufferSize;
    } else {
        if (*outBufferSize < minBufferSize) {
            *outBufferSize = minBufferSize;
        }
        *outNumPackets = *outBufferSize / maxPacketSize;
    }
}

// Callback
static void AQOutputCallback(void *inUserData,
                             AudioQueueRef inQueue,
                             AudioQueueBufferRef inCompleteAQBuffer) {
    
    Player *player = (Player *) inUserData;
    if (player->isDone) return;
    
    UInt32 numBytes;
    UInt nPackets = player->numPacketsToRead;
    CheckError(AudioFileReadPackets(player->playbackFile,
                                    false,
                                    &numBytes,
                                    player->packetDescriptions,
                                    player->packetPosition,
                                    &nPackets,
                                    inCompleteAQBuffer->mAudioData),
               "AudioFileReadPackets failed");
    
    if (nPackets > 0) {
        inCompleteAQBuffer->mAudioDataByteSize = numBytes;
        AudioQueueEnqueueBuffer(inQueue,
                                inCompleteAQBuffer,
                                player->packetDescriptions ? nPackets : 0,
                                player->packetDescriptions);
        player->packetPosition += nPackets;
    } else {
        CheckError(AudioQueueStop(inQueue,
                                  false),
                   "AudioQueueStop failed");
        player->isDone = true;
    }
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Open an audio file
        /* 5.3 - 5.4 */
        // Allocate a player struct
        Player player = {0};
        CFURLRef fileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                         kPlaybackFileLocation,
                                                         kCFURLPOSIXPathStyle,
                                                         false);
        
        CheckError(AudioFileOpenURL(fileURL,
                                    kAudioFileReadPermission,
                                    0,
                                    &player.playbackFile),
                   "AudioFileOpenURL failed: can't open provide file url");
        
        CFRelease(fileURL);
        
        
        // Set up format
        /* 5.5 */
        AudioStreamBasicDescription dataFormat;
        UInt32 propSize = sizeof(dataFormat);
        CheckError(AudioFileGetProperty(player.playbackFile,
                                        kAudioFilePropertyDataFormat,
                                        &propSize,
                                        &dataFormat),
                   "AudioFileGetProperty failed: can't get audio format data from file");
        
        // Set up queue
        /* 5.6 - 5.10 */
        AudioQueueRef queue;
        CheckError(AudioQueueNewOutput(&dataFormat,
                                       AQOutputCallback,
                                       &player,
                                       NULL,
                                       NULL,
                                       0,
                                       &queue),
                   "AudioQueueNewOutput failed");
        
        // Find buffer byte size
        UInt32 bufferByteSize;
        CalculateBytesForTime(player.playbackFile,
                              dataFormat,
                              0.5, // buffer duration
                              &bufferByteSize,
                              &player.numPacketsToRead);
        
        // Update packet descriptions if file has variable bit rate (VBR)
        bool isFormatVariableBitrate = (dataFormat.mBytesPerFrame == 0 ||
                                        dataFormat.mFramesPerPacket == 0);
        if (isFormatVariableBitrate) {
            player.packetDescriptions = (AudioStreamBasicDescription *) malloc(sizeof(AudioStreamBasicDescription) * player.numPacketsToRead);
        } else {
            player.packetDescriptions = NULL;
        }
        
        // Take care of magic cookies
        CopyEncoderCookieToQueue(player.playbackFile, queue);
        
        /* Use AudioQueue to allocate buffers,
         then send it to callback for playback,
         3 at a time (set in kNumberPlaybackBuffers up top).
         */
        AudioQueueBufferRef buffers[kNumberPlaybackBuffers];
        player.isDone = false;
        player.packetPosition = 0;
        for (int i = 0; i < kNumberPlaybackBuffers; i++) {
            CheckError(AudioQueueAllocateBuffer(queue,
                                                bufferByteSize,
                                                &buffers[i]),
                       "AudioQueueAllocateBuffer failed");
            
            // Pass allocated buffer to callback
            AQOutputCallback(&player,
                             queue,
                             buffers[i]);
            
            // set in callback if all data from file has been enqueued,
            // applies only if audio file is shorter than 3 buffers (1.5 second).
            if (player.isDone) {
                break;
            }
        }
        
        // Start queue
        /* 5.11 - 5.12 */
        CheckError(AudioQueueStart(queue,
                                   NULL),
                   "AudioQueueStart: failed");
        
        printf("Playing...\n");
        do {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode,
                               0.25,
                               false);
        } while (!player.isDone);
        
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,
                           2,
                           false);
        
        // Clean up queue
        /* 5.13 */
        player.isDone = true;
        CheckError(AudioQueueStop(queue,
                                  TRUE),
                   "AudioQueueStop failed");
        
        AudioQueueDispose(queue,
                          TRUE);
        AudioFileClose(player.playbackFile);
    }
    return 0;
}
