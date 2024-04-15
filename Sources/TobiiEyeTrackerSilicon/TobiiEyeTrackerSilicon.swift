import Combine
import Foundation

public enum TobiiData {
  case data(Float)
  case message(String)
  case errorMessage(TobiiError)
}

public enum TobiiError: Error {
  case outputError(content: String)
}

public class TobiiTracker: ObservableObject {
  /// Store the average value of Pupil diameters (left and right eye)
  public var avgPupilDiameter = PassthroughSubject<TobiiData, Never>()
  
  public var currentPupilDialect = CurrentValueSubject<Float, Error>(-1)
  
  var process = Process()
  
  var timer: AnyCancellable?
  
  /// This is the similar `avgPupilDiameter` but emitted with the control of `timer`
  public var avgPupilSizeByFrequency = PassthroughSubject<TobiiData, Never>()
  
  /// The scanning frequency, which mean howmany time we collect the tobii data
  /// from `currentPupilDialect` in one seconds
  var customFrequency: UInt
  
  init(frequency: UInt = 60) {
    self.customFrequency = frequency
  }
  
  deinit {
    timer = nil
  }
}

extension TobiiTracker {
  public func startReadPupilDiameter() {
    if process.isRunning {
      process.terminate()
    }
    // re-create the process whenver we want to use it
    // to prevent process can't launch after terminated
    process = Process()
    setupProcess()
    
    prepareToReadPupilDiameter()
    
    do {
      try process.run()
    } catch {
      print(error.localizedDescription)
      return
    }
    
    /// Assign and start the timer
    let duration = 1 / Double(customFrequency)
    self.timer = Timer.publish(every: duration, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in
        
        guard let self else {
          return
        }
        
        let pupilDialect = currentPupilDialect.value
        
        if pupilDialect != -1 {
          avgPupilSizeByFrequency.send(.data(pupilDialect))
        }
      }
  }
  
  public func stopReadPupilDiameter() {
    if process.isRunning {
      // stop the process
      process.terminate()
      
      // stop timer
      timer?.cancel()
    }
  }
}

//MARK: - setup and preparation
extension TobiiTracker {
  private func setupProcess() {
    /* Bash command:
     arch -x86_64 /usr/local/homebrew/bin/python3.10 [script.py in the bundle]
     */
    
    guard let scriptPath = Bundle.module.path(forResource: "script", ofType: "py") else {
      return
    }
    
    // because the python script will need to run as x86_64 architechture
    // we need a bit config for the command
    
    // mac M1 default python (installed by homebrew): "/usr/local/bin/python3"
    // this is the python we installed via x86_64 context
    let python = "/usr/local/homebrew/bin/python3.10"
    
    let command = "arch -x86_64 \(python) \(scriptPath)"
    
    // progress configuration
    process.arguments = ["-c", command]
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
  }
  
  private func prepareToReadPupilDiameter() {
    // install pipline for data output comunication
    let pipe = Pipe()
    process.standardOutput = pipe
    
    let fileHandle = pipe.fileHandleForReading
    fileHandle.waitForDataInBackgroundAndNotify()
    
    // Notificaiton center observer for the data output
    NotificationCenter.default.addObserver(
      forName: .NSFileHandleDataAvailable,
      object: fileHandle,
      queue: nil
    ) { [weak self] _ in
      let data = fileHandle.availableData
      if data.count > 0 {
        // we expect the echo command will show something like '{value}\n'
        // so we need to remove the newLine by dropLast
        if let output = String(data: data, encoding: .utf8)?.dropLast() {
          if let float = Float(String(output)) {
            self?.avgPupilDiameter.send(.data(float))
            self?.currentPupilDialect.send(float)
          } else {
            if String(output).contains("Eye tracker connected") {
              self?.avgPupilDiameter.send(.message(String(output)))
            } else {
              let error = TobiiError.outputError(content: String(output))
              self?.avgPupilDiameter.send(.errorMessage(error))
              self?.stopReadPupilDiameter()
            }
          }
        }
        fileHandle.waitForDataInBackgroundAndNotify()
      } else {
        // terminated state or fail state
        print("terminated state or fail state, stop the process now.")
        self?.stopReadPupilDiameter()
      }
    }
  }
}
