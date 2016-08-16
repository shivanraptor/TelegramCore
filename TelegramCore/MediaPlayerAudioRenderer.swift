import Foundation
import SwiftSignalKit
import CoreMedia
import AVFoundation

private enum AudioPlayerRendererState {
    case paused
    case playing(didSetRate: Bool)
}

private final class AudioPlayerRendererBufferContext {
    var state: AudioPlayerRendererState = .paused
    let timebase: CMTimebase
    let buffer: RingByteBuffer
    var bufferMaxChannelSampleIndex: Int64 = 0
    var lowWaterSize: Int
    var notifyLowWater: () -> Void
    var notifiedLowWater = false
    var overflowData = Data()
    var overflowDataMaxChannelSampleIndex: Int64 = 0
    var renderTimestampTick: Int64 = 0
    
    init(timebase: CMTimebase, buffer: RingByteBuffer, lowWaterSize: Int, notifyLowWater: () -> Void) {
        self.timebase = timebase
        self.buffer = buffer
        self.lowWaterSize = lowWaterSize
        self.notifyLowWater = notifyLowWater
    }
}

private let audioPlayerRendererBufferContextMap = Atomic<[Int32: Atomic<AudioPlayerRendererBufferContext>]>(value: [:])
private let audioPlayerRendererQueue = Queue()

private var _nextPlayerRendererBufferContextId: Int32 = 1
private func registerPlayerRendererBufferContext(_ context: Atomic<AudioPlayerRendererBufferContext>) -> Int32 {
    var id: Int32 = 0
    
    let _ = audioPlayerRendererBufferContextMap.modify { contextMap in
        id = _nextPlayerRendererBufferContextId
        _nextPlayerRendererBufferContextId += 1
        
        var contextMap = contextMap
        contextMap[id] = context
        return contextMap
    }
    return id
}

private func unregisterPlayerRendererBufferContext(_ id: Int32) {
    let _ = audioPlayerRendererBufferContextMap.modify { contextMap in
        var contextMap = contextMap
        let _ = contextMap.removeValue(forKey: id)
        return contextMap
    }
}

private func withPlayerRendererBuffer(_ id: Int32, _ f: @noescape(Atomic<AudioPlayerRendererBufferContext>) -> Void) {
    audioPlayerRendererBufferContextMap.with { contextMap in
        if let context = contextMap[id] {
            f(context)
        }
    }
}

private let kOutputBus: UInt32 = 0
private let kInputBus: UInt32 = 1

private func rendererInputProc(refCon: UnsafeMutablePointer<Void>, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp: UnsafePointer<AudioTimeStamp>, inBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let ioData = ioData else {
        return noErr
    }
    
    let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
    
    var rendererFillOffset = (0, 0)
    var notifyLowWater: (() -> Void)?
    
    withPlayerRendererBuffer(Int32(unsafeBitCast(refCon, to: intptr_t.self)), { context in
        context.with { context in
            switch context.state {
                case let .playing(didSetRate):
                    if context.buffer.availableBytes != 0 {
                        let sampleIndex = context.bufferMaxChannelSampleIndex - Int64(context.buffer.availableBytes / (2 *
                            2))
                        
                        if !didSetRate {
                            context.state = .playing(didSetRate: true)
                            let masterClock: CMClockOrTimebase
                            if #available(iOS 9.0, *) {
                                masterClock = CMTimebaseCopyMaster(context.timebase)!
                            } else {
                                masterClock = CMTimebaseGetMaster(context.timebase)!
                            }
                            CMTimebaseSetRateAndAnchorTime(context.timebase, 1.0, CMTimeMake(sampleIndex, 44100), CMSyncGetTime(masterClock))
                        } else {
                            context.renderTimestampTick += 1
                            if context.renderTimestampTick % 1000 == 0 {
                                let delta = (Double(sampleIndex) / 44100.0) - CMTimeGetSeconds(CMTimebaseGetTime(context.timebase))
                                if delta > 0.01 {
                                    CMTimebaseSetTime(context.timebase, CMTimeMake(sampleIndex, 44100))
                                }
                            }
                        }
                        
                        let rendererBuffer = context.buffer
                        
                        while rendererFillOffset.0 < bufferList.count {
                            if let bufferData = bufferList[rendererFillOffset.0].mData {
                                let bufferDataSize = Int(bufferList[rendererFillOffset.0].mDataByteSize)
                                
                                let dataOffset = rendererFillOffset.1
                                if dataOffset == bufferDataSize {
                                    rendererFillOffset = (rendererFillOffset.0 + 1, 0)
                                    continue
                                }
                                
                                let consumeCount = bufferDataSize - dataOffset
                                
                                let actualConsumedCount = rendererBuffer.dequeue(bufferData.advanced(by: dataOffset), count: consumeCount)
                                rendererFillOffset.1 += actualConsumedCount
                                
                                if actualConsumedCount == 0 {
                                    break
                                }
                            } else {
                                break
                            }
                        }
                    }
                
                    if !context.notifiedLowWater {
                        let availableBytes = context.buffer.availableBytes
                        if availableBytes <= context.lowWaterSize {
                            context.notifiedLowWater = true
                            notifyLowWater = context.notifyLowWater
                        }
                    }
                case .paused:
                    break
            }
        }
    })
    
    for i in rendererFillOffset.0 ..< bufferList.count {
        var dataOffset = 0
        if i == rendererFillOffset.0 {
            dataOffset = rendererFillOffset.1
        }
        if let data = bufferList[i].mData {
            memset(data.advanced(by: dataOffset), 0, Int(bufferList[i].mDataByteSize) - dataOffset)
        }
    }
    
    if let notifyLowWater = notifyLowWater {
        notifyLowWater()
    }
    
    return noErr
}

private struct RequestingFramesContext {
    let queue: DispatchQueue
    let takeFrame: () -> MediaTrackFrameResult
}

private final class AudioPlayerRendererContext {
    let audioStreamDescription: AudioStreamBasicDescription
    let bufferSizeInSeconds: Int = 5
    let lowWaterSizeInSeconds: Int = 2
    
    let controlTimebase: CMTimebase
    
    var audioUnit: AudioComponentInstance?
    
    var bufferContextId: Int32!
    let bufferContext: Atomic<AudioPlayerRendererBufferContext>
    
    var requestingFramesContext: RequestingFramesContext?
    
    init(controlTimebase: CMTimebase) {
        assert(audioPlayerRendererQueue.isCurrent())
        
        self.controlTimebase = controlTimebase
        
        self.audioStreamDescription = audioRendererNativeStreamDescription()
        
        let bufferSize = Int(self.audioStreamDescription.mSampleRate) * self.bufferSizeInSeconds * Int(self.audioStreamDescription.mBytesPerFrame)
        let lowWaterSize = Int(self.audioStreamDescription.mSampleRate) * self.lowWaterSizeInSeconds * Int(self.audioStreamDescription.mBytesPerFrame)
        
        var notifyLowWater: () -> Void = { }
        
        self.bufferContext = Atomic(value: AudioPlayerRendererBufferContext(timebase: controlTimebase, buffer: RingByteBuffer(size: bufferSize), lowWaterSize: lowWaterSize, notifyLowWater: {
            notifyLowWater()
        }))
        self.bufferContextId = registerPlayerRendererBufferContext(self.bufferContext)
        
        notifyLowWater = { [weak self] in
            audioPlayerRendererQueue.async {
                if let strongSelf = self {
                    strongSelf.checkBuffer()
                }
            }
        }
    }
    
    deinit {
        assert(audioPlayerRendererQueue.isCurrent())
        
        unregisterPlayerRendererBufferContext(self.bufferContextId)
        
        self.closeAudioUnit()
    }
    
    private func setPlaying(_ playing: Bool) {
        assert(audioPlayerRendererQueue.isCurrent())
        
        self.bufferContext.with { context in
            if playing {
                context.state = .playing(didSetRate: false)
            } else {
                context.state = .paused
                CMTimebaseSetRate(context.timebase, 0.0)
            }
        }
    }
    
    private func flushBuffers(at timestamp: CMTime, completion: () -> Void) {
        assert(audioPlayerRendererQueue.isCurrent())
        
        self.bufferContext.with { context in
            context.buffer.clear()
            context.bufferMaxChannelSampleIndex = 0
            context.notifiedLowWater = false
            context.overflowData = Data()
            context.overflowDataMaxChannelSampleIndex = 0
            CMTimebaseSetTime(context.timebase, timestamp)
            
            switch context.state {
                case .playing:
                    context.state = .playing(didSetRate: false)
                case .paused:
                    break
            }
            
            completion()
        }
    }
    
    private func startAudioUnit() {
        if self.audioUnit == nil {
            guard let _ = try? AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback) else {
                return
            }
            guard let _ = try? AVAudioSession.sharedInstance().setActive(true) else {
                return
            }
            
            var desc = AudioComponentDescription()
            desc.componentType = kAudioUnitType_Output
            desc.componentSubType = kAudioUnitSubType_RemoteIO
            desc.componentFlags = 0
            desc.componentFlagsMask = 0
            desc.componentManufacturer = kAudioUnitManufacturer_Apple
            guard let inputComponent = AudioComponentFindNext(nil, &desc) else {
                return
            }
            
            var maybeAudioUnit: AudioComponentInstance?
            
            guard AudioComponentInstanceNew(inputComponent, &maybeAudioUnit) == noErr else {
                return
            }
            
            guard let audioUnit = maybeAudioUnit else {
                return
            }
            
            var one: UInt32 = 1
            guard AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &one, 4) == noErr else {
                AudioComponentInstanceDispose(audioUnit)
                return
            }
            
            var audioStreamDescription = self.audioStreamDescription
            guard AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioStreamDescription, UInt32(sizeof(AudioStreamBasicDescription.self))) == noErr else {
                AudioComponentInstanceDispose(audioUnit)
                return
            }
            
            var callbackStruct = AURenderCallbackStruct()
            callbackStruct.inputProc = rendererInputProc
            callbackStruct.inputProcRefCon = unsafeBitCast(intptr_t(self.bufferContextId), to: UnsafeMutablePointer<Void>.self)
            guard AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, kOutputBus, &callbackStruct, UInt32(sizeof(AURenderCallbackStruct.self))) == noErr else {
                AudioComponentInstanceDispose(audioUnit)
                return
            }
            
            guard AudioUnitInitialize(audioUnit) == noErr else {
                AudioComponentInstanceDispose(audioUnit)
                return
            }
            
            guard AudioOutputUnitStart(audioUnit) == noErr else {
                AudioComponentInstanceDispose(audioUnit)
                return
            }
            
            self.audioUnit = audioUnit
        }
    }
    
    private func closeAudioUnit() {
        assert(audioPlayerRendererQueue.isCurrent())
        
        if let audioUnit = self.audioUnit {
            var status = noErr
            
            self.bufferContext.with { context in
                context.buffer.clear()
            }
            
            status = AudioOutputUnitStop(audioUnit)
            if status != noErr {
                trace("AudioPlayerRenderer", what: "AudioOutputUnitStop error \(status)")
            }
            
            status = AudioComponentInstanceDispose(audioUnit);
            if status != noErr {
                trace("AudioPlayerRenderer", what: "AudioComponentInstanceDispose error \(status)")
            }
            self.audioUnit = nil
        }
    }
    
    func checkBuffer() {
        assert(audioPlayerRendererQueue.isCurrent())
        
        while true {
            let bytesToRequest = self.bufferContext.with { context -> Int in
                let availableBytes = context.buffer.availableBytes
                if availableBytes <= context.lowWaterSize {
                    return context.buffer.size - availableBytes
                } else {
                    return 0
                }
            }
            
            if bytesToRequest == 0 {
                self.bufferContext.with { context in
                    context.notifiedLowWater = false
                }
                break
            }
            
            let overflowTakenLength = self.bufferContext.with { context -> Int in
                let takeLength = min(context.overflowData.count, bytesToRequest)
                if takeLength != 0 {
                    if takeLength == context.overflowData.count {
                        let data = context.overflowData
                        context.overflowData = Data()
                        self.enqueueSamples(data, sampleIndex: context.overflowDataMaxChannelSampleIndex - (data.count / (2 * 2)))
                    } else {
                        let data = context.overflowData.subdata(in: 0 ..< takeLength)
                        self.enqueueSamples(data, sampleIndex: context.overflowDataMaxChannelSampleIndex - (context.overflowData.count / (2 * 2)))
                        context.overflowData.replaceSubrange(0 ..< takeLength, with: Data())
                    }
                }
                return takeLength
            }
            
            if overflowTakenLength != 0 {
                continue
            }
            
            if let requestingFramesContext = self.requestingFramesContext {
                requestingFramesContext.queue.async {
                    let takenFrame = requestingFramesContext.takeFrame()
                    audioPlayerRendererQueue.async {
                        switch takenFrame {
                            case let .frame(frame):
                                if let dataBuffer = CMSampleBufferGetDataBuffer(frame.sampleBuffer) {
                                    let dataLength = CMBlockBufferGetDataLength(dataBuffer)
                                    let takeLength = min(dataLength, bytesToRequest)
                                    
                                    let pts = CMSampleBufferGetPresentationTimeStamp(frame.sampleBuffer)
                                    let bufferSampleIndex = CMTimeConvertScale(pts, 44100, .roundAwayFromZero).value
                                    
                                    let bytes = malloc(takeLength)!
                                    CMBlockBufferCopyDataBytes(dataBuffer, 0, takeLength, bytes)
                                    self.enqueueSamples(Data(bytesNoCopy: UnsafeMutablePointer<UInt8>(bytes), count: takeLength, deallocator: .free), sampleIndex: bufferSampleIndex)
                                    
                                    if takeLength < dataLength {
                                        self.bufferContext.with { context in
                                            let copyOffset = context.overflowData.count
                                            context.overflowData.count += dataLength - takeLength
                                            context.overflowData.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                                                CMBlockBufferCopyDataBytes(dataBuffer, takeLength, dataLength - takeLength, bytes.advanced(by: copyOffset))
                                            }
                                        }
                                    }
                                    
                                    self.checkBuffer()
                                } else {
                                    assertionFailure()
                                }
                            case .skipFrame:
                                self.checkBuffer()
                                break
                            case .noFrames:
                                self.requestingFramesContext = nil
                        }
                    }
                }
            } else {
                self.bufferContext.with { context in
                    context.notifiedLowWater = false
                }
            }
            
            break
        }
    }
    
    private func enqueueSamples(_ data: Data, sampleIndex: Int64) {
        assert(audioPlayerRendererQueue.isCurrent())
        
        self.bufferContext.with { context in
            let bytesToCopy = min(context.buffer.size - context.buffer.availableBytes, data.count)
            data.withUnsafeBytes { (bytes: UnsafePointer<Void>) -> Void in
                let _ = context.buffer.enqueue(bytes, count: bytesToCopy)
                context.bufferMaxChannelSampleIndex = sampleIndex + (data.count / (2 * 2))
            }
        }
    }
    
    func beginRequestingFrames(queue: DispatchQueue, takeFrame: () -> MediaTrackFrameResult) {
        if let _ = self.requestingFramesContext {
            return
        }
        
        self.requestingFramesContext = RequestingFramesContext(queue: queue, takeFrame: takeFrame)
        
        self.checkBuffer()
    }
    
    func endRequestingFrames() {
        self.requestingFramesContext = nil
    }
}

private func audioRendererNativeStreamDescription() -> AudioStreamBasicDescription {
    var canonicalBasicStreamDescription = AudioStreamBasicDescription()
    canonicalBasicStreamDescription.mSampleRate = 44100.00
    canonicalBasicStreamDescription.mFormatID = kAudioFormatLinearPCM
    canonicalBasicStreamDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
    canonicalBasicStreamDescription.mFramesPerPacket = 1
    canonicalBasicStreamDescription.mChannelsPerFrame = 2
    canonicalBasicStreamDescription.mBytesPerFrame = 2 * 2
    canonicalBasicStreamDescription.mBitsPerChannel = 8 * 2
    canonicalBasicStreamDescription.mBytesPerPacket = 2 * 2
    return canonicalBasicStreamDescription
}

final class MediaPlayerAudioRenderer {
    private var contextRef: Unmanaged<AudioPlayerRendererContext>?
    
    private let audioClock: CMClock
    let audioTimebase: CMTimebase
    
    var rate: Double = 0.0 {
        didSet {
            let rate = self.rate
            if !oldValue.isEqual(to: rate) {
                assert(rate.isEqual(to: 1.0) || rate.isEqual(to: 0.0))
                
                audioPlayerRendererQueue.async {
                    if let contextRef = self.contextRef {
                        let context = contextRef.takeUnretainedValue()
                        context.setPlaying(rate.isEqual(to: 1.0))
                    }
                }
            }
        }
    }
    
    init() {
        var audioClock: CMClock?
        CMAudioClockCreate(nil, &audioClock)
        self.audioClock = audioClock!
        
        var audioTimebase: CMTimebase?
        CMTimebaseCreateWithMasterClock(nil, audioClock!, &audioTimebase)
        self.audioTimebase = audioTimebase!
        
        audioPlayerRendererQueue.async {
            let context = AudioPlayerRendererContext(controlTimebase: audioTimebase!)
            self.contextRef = Unmanaged.passRetained(context)
        }
    }
    
    deinit {
        let contextRef = self.contextRef
        audioPlayerRendererQueue.async {
            contextRef?.release()
        }
    }
    
    func start() {
        audioPlayerRendererQueue.async {
            if let contextRef = self.contextRef {
                let context = contextRef.takeUnretainedValue()
                context.startAudioUnit()
            }
        }
    }
    
    func stop() {
        audioPlayerRendererQueue.async {
            if let contextRef = self.contextRef {
                let context = contextRef.takeUnretainedValue()
                context.closeAudioUnit()
            }
        }
    }
    
    func beginRequestingFrames(queue: DispatchQueue, takeFrame: () -> MediaTrackFrameResult) {
        audioPlayerRendererQueue.async {
            if let contextRef = self.contextRef {
                let context = contextRef.takeUnretainedValue()
                context.beginRequestingFrames(queue: queue, takeFrame: takeFrame)
            }
        }
    }
    
    func flushBuffers(at timestamp: CMTime, completion: () -> Void) {
        audioPlayerRendererQueue.async {
            if let contextRef = self.contextRef {
                let context = contextRef.takeUnretainedValue()
                context.flushBuffers(at: timestamp, completion: completion)
            }
        }
    }
}
