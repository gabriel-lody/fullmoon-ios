//
//  LLMEvaluator.swift
//  fullmoon
//
//  Created by Gabriel Lody on 10/4/24.
//

import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom
import SwiftUI

enum LLMEvaluatorError: Error {
    case modelNotFound(String)
}

@Observable
@MainActor
class LLMEvaluator {
    var running = false
    var cancelled = false
    var output = ""
    var modelInfo = ""
    var stat = ""
    var progress = 0.0
    var thinkingTime: TimeInterval?
    var collapsed: Bool = false
    var isThinking: Bool = false

    var elapsedTime: TimeInterval? {
        if let startTime {
            return Date().timeIntervalSince(startTime)
        }

        return nil
    }

    private var startTime: Date?

    var modelConfiguration = ModelConfiguration.defaultModel

    func switchModel(_ model: ModelConfiguration) async {
        progress = 0.0 // reset progress
        loadState = .idle
        modelConfiguration = model
        _ = try? await load(modelName: model.name)
    }

    /// parameters controlling the output
    let generateParameters = GenerateParameters(temperature: 0.5)
    let maxTokens = 4096

    /// update the display every N tokens -- 4 looks like it updates continuously
    /// and is low overhead.  observed ~15% reduction in tokens/s when updating
    /// on every token
    let displayEveryNTokens = 4

    enum LoadState {
        case idle
        case loaded(ModelContainer)
    }

    var loadState = LoadState.idle

    /// load and return the model -- can be called multiple times, subsequent calls will
    /// just return the loaded model
    func load(modelName: String) async throws -> ModelContainer {
        guard let model = ModelConfiguration.getModelByName(modelName) else {
            throw LLMEvaluatorError.modelNotFound(modelName)
        }

        switch loadState {
        case .idle:
            // limit the buffer cache
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

            let modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: model) {
                [modelConfiguration] progress in
                Task { @MainActor in
                    self.modelInfo =
                        "Downloading \(modelConfiguration.name): \(Int(progress.fractionCompleted * 100))%"
                    self.progress = progress.fractionCompleted
                }
            }
            modelInfo =
                "Loaded \(modelConfiguration.id).  Weights: \(MLX.GPU.activeMemory / 1024 / 1024)M"
            loadState = .loaded(modelContainer)
            return modelContainer

        case let .loaded(modelContainer):
            return modelContainer
        }
    }

    func stop() {
        isThinking = false
        cancelled = true
    }

    func generate(modelName: String, thread: Thread, systemPrompt: String) async -> String {
        // Start high-level signpost for Instruments
        DebugLogger.shared.beginSignpost("LLM-Generate", metadata: "model=\(modelName)")

        DebugLogger.shared.logWithMemory("🟠 [LLM-1] generate() called with thread: \(thread.id)")
        guard !running else {
            DebugLogger.shared.log("🟠 [LLM-1a] already running, returning empty")
            DebugLogger.shared.endSignpost("LLM-Generate", metadata: "aborted-already-running")
            return ""
        }

        running = true
        cancelled = false
        output = ""
        startTime = Date()

        do {
            DebugLogger.shared.beginSignpost("LLM-LoadModel", metadata: modelName)
            DebugLogger.shared.logWithMemory("🟠 [LLM-2] loading model: \(modelName)")
            let modelContainer = try await load(modelName: modelName)
            DebugLogger.shared.logWithMemory("🟠 [LLM-3] model loaded successfully")
            DebugLogger.shared.endSignpost("LLM-LoadModel")

            DebugLogger.shared.log("🟠 [LLM-4] getting configuration")
            let configuration = await modelContainer.configuration
            DebugLogger.shared.log("🟠 [LLM-5] configuration retrieved")

            // Extract messages from SwiftData and convert to plain dictionaries
            // BEFORE entering perform block to avoid passing SwiftData objects
            // to background thread
            DebugLogger.shared.log("🟠 [LLM-6] extracting and converting messages from thread")
            let messages = thread.sortedMessages
            DebugLogger.shared.log("🟠 [LLM-6a] extracted \(messages.count) messages")

            // Convert SwiftData Message objects to plain dictionaries immediately
            // to detach from ModelContext
            let messageDicts: [[String: String]] = messages.map { message in
                [
                    "role": message.role.rawValue,
                    "content": message.content
                ]
            }
            DebugLogger.shared.log("🟠 [LLM-6b] converted to \(messageDicts.count) plain dictionaries")

            // augment the prompt as needed
            DebugLogger.shared.log("🟠 [LLM-7] calling getPromptHistory")
            let promptHistory = await configuration.getPromptHistory(messageDicts: messageDicts, systemPrompt: systemPrompt)
            DebugLogger.shared.log("🟠 [LLM-8] promptHistory received with \(promptHistory.count) items")

            if configuration.modelType == .reasoning {
                DebugLogger.shared.log("🟠 [LLM-9] reasoning model detected")
                isThinking = true
            }

            // each time you generate you will get something new
            DebugLogger.shared.log("🟠 [LLM-10] seeding MLXRandom")
            MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))

            // Critical section - this is where the crash happens
            DebugLogger.shared.beginSignpost("MLX-Perform", metadata: "CRITICAL-SECTION")
            DebugLogger.shared.logWithMemory("🟠 [LLM-11] calling modelContainer.perform")
            DebugLogger.shared.logMemoryPressure()

            let result = try await modelContainer.perform { context in
                DebugLogger.shared.logWithMemory("🟠 [LLM-12] inside perform block, preparing input")

                DebugLogger.shared.beginSignpost("MLX-PrepareInput")
                let input = try await context.processor.prepare(input: .init(messages: promptHistory))
                DebugLogger.shared.endSignpost("MLX-PrepareInput")
                DebugLogger.shared.logWithMemory("🟠 [LLM-13] input prepared, calling MLXLMCommon.generate")

                // Final checkpoint before MLX native code
                DebugLogger.shared.eventSignpost("MLX-EnteringNativeGenerate", metadata: "LAST-SWIFT-CHECKPOINT")
                DebugLogger.shared.logMemoryPressure()

                return try MLXLMCommon.generate(
                    input: input, parameters: generateParameters, context: context
                ) { tokens in
                    // If we get here, the crash didn't happen in MLX initialization
                    DebugLogger.shared.log("🟠 [LLM-13a] callback called with \(tokens.count) tokens")

                    var cancelled = false
                    Task { @MainActor in
                        cancelled = self.cancelled
                    }

                    // update the output -- this will make the view show the text as it generates
                    if tokens.count % displayEveryNTokens == 0 {
                        DebugLogger.shared.log("🟠 [LLM-13b] updating output at \(tokens.count) tokens")
                        let text = context.tokenizer.decode(tokens: tokens)
                        Task { @MainActor in
                            self.output = text
                        }
                    }

                    if tokens.count >= maxTokens || cancelled {
                        DebugLogger.shared.log("🟠 [LLM-13c] stopping generation")
                        return .stop
                    } else {
                        return .more
                    }
                }
            }

            DebugLogger.shared.endSignpost("MLX-Perform")
            DebugLogger.shared.logWithMemory("🟠 [LLM-14] modelContainer.perform completed")

            // update the text if needed, e.g. we haven't displayed because of displayEveryNTokens
            if result.output != output {
                output = result.output
            }
            stat = " Tokens/second: \(String(format: "%.3f", result.tokensPerSecond))"
            DebugLogger.shared.log("🟠 [LLM-15] generation completed successfully")
            DebugLogger.shared.endSignpost("LLM-Generate", metadata: "success")

        } catch {
            output = "Failed: \(error)"
            DebugLogger.shared.log("🔴 [LLM-ERROR] \(error)")
            DebugLogger.shared.endSignpost("LLM-Generate", metadata: "error=\(error)")
        }

        running = false
        DebugLogger.shared.logMemoryPressure()
        return output
    }
}
