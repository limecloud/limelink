import SwiftUI
@preconcurrency import Speech
@preconcurrency import AVFoundation

@MainActor final class VoiceDraft: ObservableObject {
    @Published var recording=false
    @Published var message="语音仅生成草稿，发送仍需点击确认。"
    private let engine=AVAudioEngine()
    private var task:SFSpeechRecognitionTask?
    private var request:SFSpeechAudioBufferRecognitionRequest?
    private var timer:Task<Void,Never>?
    private var generation=0
    func start(result:@escaping @MainActor (String)->Void) {
        guard !recording else{return}
        Task {
            let authorization=await withCheckedContinuation{continuation in SFSpeechRecognizer.requestAuthorization{continuation.resume(returning:$0)}}
            guard authorization == .authorized else{message="请在系统设置中允许语音识别。";return}
            let microphone=await AVCaptureDevice.requestAccess(for:.audio)
            guard microphone else{message="请允许麦克风访问。";return}
            guard let recognizer=SFSpeechRecognizer(locale:Locale(identifier:"zh-CN")),recognizer.isAvailable else{message="系统语音识别当前不可用。";return}
            #if os(iOS)
            do{try AVAudioSession.sharedInstance().setCategory(.record,mode:.measurement,options:.duckOthers);try AVAudioSession.sharedInstance().setActive(true)}catch{message="无法启动系统音频会话";return}
            #endif
            let request=SFSpeechAudioBufferRecognitionRequest();request.shouldReportPartialResults=true
            self.request=request;generation+=1;let current=generation
            let node=engine.inputNode,format=node.outputFormat(forBus:0)
            guard format.sampleRate>0,format.channelCount>0 else{message="没有可用麦克风";return}
            node.installTap(onBus:0,bufferSize:1024,format:format){buffer,_ in request.append(buffer)}
            engine.prepare()
            do{try engine.start()}catch{node.removeTap(onBus:0);message="录音启动失败";return}
            recording=true;message="正在识别，最多 30 秒；系统服务可能处理录音。"
            task=recognizer.recognitionTask(with:request){[weak self] response,error in
                let text=response?.bestTranscription.formattedString
                let finished=response?.isFinal == true || error != nil
                Task{@MainActor in
                    guard let self,self.generation==current else{return}
                    if let text{result(text)}
                    if finished{self.stop()}
                }
            }
            timer=Task{[weak self] in try? await Task.sleep(for:.seconds(30));guard !Task.isCancelled else{return};self?.stop()}
        }
    }
    func stop(){
        timer?.cancel();timer=nil
        guard recording else{return};recording=false
        engine.stop();engine.inputNode.removeTap(onBus:0);request?.endAudio();task?.cancel();request=nil;task=nil
        generation+=1;message="录音已停止，请检查草稿后确认发送。"
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
        #endif
    }
}
