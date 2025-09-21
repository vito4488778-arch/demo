//
//  ContentView.swift
//  demo
//
//  Created by 114iosClassStudent04 on 2025/9/5.
//

import SwiftUI
import UIKit
import AVFoundation

struct ContentView: View {
    var body: some View {
        BreakoutGameView()
    }
}

private enum GameStatus {
    case ready
    case running
    case paused
    case won
    case lost
}

private struct Brick: Identifiable {
    let id = UUID()
    var rect: CGRect
    var hitPoints: Int
    var score: Int
    var color: Color

    var isAlive: Bool { hitPoints > 0 }
}

private struct BreakoutGameView: View {
    // MARK: - Game State
    @State private var status: GameStatus = .ready

    // World
    @State private var worldSize: CGSize = .zero

    // Paddle
    @State private var paddleWidth: CGFloat = 120
    @State private var paddleHeight: CGFloat = 16
    @State private var paddlePosition: CGPoint = .zero

    // Ball
    @State private var ballRadius: CGFloat = 10
    @State private var ballPosition: CGPoint = .zero
    @State private var ballVelocity: CGVector = .zero

    // 物理參數
    private var constantSpeed: CGFloat { max(140, worldSize.height * 0.6) } // 依裝置高度縮放
    private let restitution: CGFloat = 1.0
    private let tangentBoost: CGFloat = 0.35
    private let minAngle: CGFloat = .pi * 0.08
    private let maxAngle: CGFloat = .pi * 0.92

    // Bricks
    @State private var bricks: [Brick] = []

    // HUD
    @State private var score: Int = 0
    @State private var lives: Int = 3

    // Input
    @State private var dragOffsetX: CGFloat? = nil

    // Fixed-step physics accumulator
    @State private var lastFrameTime: TimeInterval = 0
    @State private var accumulator: TimeInterval = 0
    private let physicsDT: TimeInterval = 1.0 / 240.0

    // Haptics
    private let haptics = Haptics()

    // BGM
    @State private var bgm = BGMPlayer.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                Image("SpaceBG")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()

                Color.black.opacity(0.25)
                    .ignoresSafeArea()

                // Bricks (use material images instead of solid colors)
                ForEach(bricks) { brick in
                    if brick.isAlive {
                        BrickView(brick: brick)
                            .frame(width: brick.rect.width, height: brick.rect.height)
                            .position(x: brick.rect.midX, y: brick.rect.midY)
                            .shadow(color: .white.opacity(0.08), radius: 2, x: 0, y: 1)
                    }
                }

                // Paddle
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.9))
                    .frame(width: paddleWidth, height: paddleHeight)
                    .position(paddlePosition)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                handlePaddleDrag(value, in: geo.size)
                            }
                            .onEnded { _ in
                                dragOffsetX = nil
                            }
                    )
                    .shadow(color: .white.opacity(0.5), radius: 6)

                // Ball
                Circle()
                    .fill(.yellow)
                    .frame(width: ballRadius * 2, height: ballRadius * 2)
                    .position(ballPosition)
                    .shadow(color: .white.opacity(0.6), radius: 6)

                // Borders (visual)
                Rectangle()
                    .strokeBorder(.white.opacity(0.2), lineWidth: 2)
                    .ignoresSafeArea()
                    .blendMode(.plusLighter)

                // HUD
                VStack(spacing: 10) {
                    HStack {
                        Label("Score: \(score)", systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                        Spacer()
                        Label("Lives: \(lives)", systemImage: "heart.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()

                    VStack(spacing: 10) {
                        switch status {
                        case .ready:
                            Text("拖曳板子接球，打掉所有磚塊！")
                                .foregroundStyle(.white.opacity(0.95))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        case .paused:
                            Text("已暫停")
                                .foregroundStyle(.white.opacity(0.95))
                        case .won:
                            Text("你贏了！")
                                .font(.largeTitle).bold()
                                .foregroundStyle(.green)
                        case .lost:
                            Text("遊戲結束")
                                .font(.largeTitle).bold()
                                .foregroundStyle(.red)
                        case .running:
                            EmptyView()
                        }

                        HStack(spacing: 12) {
                            if status == .running {
                                Button {
                                    pauseGame()
                                } label: {
                                    Label("暫停", systemImage: "pause.fill")
                                }
                                .buttonStyle(.bordered)
                            } else if status == .paused {
                                Button {
                                    resumeGame()
                                } label: {
                                    Label("繼續", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button {
                                    startOrRestart(keepScore: false)
                                } label: {
                                    Label("開始", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            Button {
                                startOrRestart(keepScore: true)
                            } label: {
                                Label("重置關卡", systemImage: "arrow.clockwise.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .padding()
            }
            .onAppear {
                setupWorld(size: geo.size)
                bgm.play(loop: true) // 播放並循環
            }
            .onChange(of: geo.size) { newSize in
                setupWorld(size: newSize, keepRunning: status == .running || status == .paused)
            }
            .onDisappear {
                bgm.stop()
            }
            .overlay(gameLoopOverlay)
        }
    }

    // MARK: - Game Loop with fixed physics step
    private var gameLoopOverlay: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Color.clear
                .onChange(of: t) { _ in
                    guard status == .running else {
                        lastFrameTime = t
                        return
                    }
                    if lastFrameTime == 0 { lastFrameTime = t }
                    let frameDT = max(0, t - lastFrameTime)
                    lastFrameTime = t
                    accumulator += frameDT

                    let maxSteps = 8
                    var steps = 0
                    while accumulator >= physicsDT && steps < maxSteps {
                        physicsStep(dt: CGFloat(physicsDT))
                        accumulator -= physicsDT
                        steps += 1
                    }
                }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Setup
    private func setupWorld(size: CGSize, keepRunning: Bool = false) {
        worldSize = size

        paddleWidth = max(90, min(size.width * 0.35, 160))
        paddleHeight = 16
        paddlePosition = CGPoint(x: size.width / 2, y: size.height - 60)

        ballRadius = 10
        if status == .ready || !keepRunning {
            resetBallOnPaddle()
        }

        bricks = makeBricks(in: size)

        if !keepRunning {
            score = 0
            lives = 3
            status = .ready
        }

        lastFrameTime = 0
        accumulator = 0
    }

    private func makeBricks(in size: CGSize) -> [Brick] {
        let topMargin: CGFloat = 90
        let sideMargin: CGFloat = 16
        let rows = 6
        let cols = 8
        let spacing: CGFloat = 6

        let totalSpacingX = spacing * CGFloat(cols - 1)
        let availableWidth = size.width - sideMargin * 2 - totalSpacingX
        let brickWidth = max(40, availableWidth / CGFloat(cols))
        let brickHeight: CGFloat = 22

        var arr: [Brick] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let x = sideMargin + CGFloat(c) * (brickWidth + spacing)
                let y = topMargin + CGFloat(r) * (brickHeight + spacing)
                let rect = CGRect(x: x, y: y, width: brickWidth, height: brickHeight)

                let hp = max(1, 1 + (rows - 1 - r) / 2)
                let score = 50 * hp
                // 用 hue 生成顏色，渲染時會用材質圖片覆蓋
                let color = Color(hue: Double(r) / Double(rows) * 0.9, saturation: 0.7, brightness: 0.9)

                arr.append(Brick(rect: rect, hitPoints: hp, score: score, color: color))
            }
        }
        return arr
    }

    // MARK: - Controls
    private func handlePaddleDrag(_ value: DragGesture.Value, in size: CGSize) {
        let x = value.location.x
        if dragOffsetX == nil {
            dragOffsetX = x - paddlePosition.x
        }
        let targetX = x - (dragOffsetX ?? 0)
        let clampedX = max(paddleWidth / 2, min(size.width - paddleWidth / 2, targetX))
        paddlePosition.x = clampedX

        if status == .ready || (status == .paused && ballVelocity == .zero) {
            ballPosition.x = clampedX
        }
    }

    // MARK: - Game Flow
    private func startOrRestart(keepScore: Bool) {
        let currentScore = keepScore ? score : 0
        setupWorld(size: worldSize)
        score = currentScore
        status = .ready
        haptics.soft()
        launchBall()
    }

    private func pauseGame() {
        guard status == .running else { return }
        status = .paused
        bgm.setVolume(0.25, fadeDuration: 0.2) // 暫停時降低音量
        haptics.light()
    }

    private func resumeGame() {
        guard status == .paused else { return }
        status = .running
        bgm.setVolume(0.6, fadeDuration: 0.2) // 繼續時恢復音量
        haptics.light()
    }

    private func endGame(won: Bool) {
        status = won ? .won : .lost
        if won { haptics.success(light: false) } else { haptics.error() }
        // 結束時做個淡出
        bgm.setVolume(0.2, fadeDuration: 0.4)
        ballVelocity = .zero
    }

    // MARK: - Ball Control
    private func resetBallOnPaddle() {
        ballPosition = CGPoint(x: paddlePosition.x, y: paddlePosition.y - paddleHeight / 2 - ballRadius - 2)
        ballVelocity = .zero
    }

    private func launchBall() {
        var angle = CGFloat.pi * (1.2 + CGFloat.random(in: -0.15...0.15))
        angle = clampAngle(angle)
        let v = CGVector(dx: cos(angle), dy: sin(angle))
        let n = normalize(v)
        ballVelocity = CGVector(dx: n.dx * constantSpeed, dy: n.dy * constantSpeed)
        status = .running
        // 遊戲開始把音量拉回正常
        bgm.setVolume(0.6, fadeDuration: 0.25)
        haptics.success(light: true)
    }

    // MARK: - Physics Step (semi-implicit Euler)
    private func physicsStep(dt: CGFloat) {
        let damping: CGFloat = 0.000
        ballVelocity.dx *= (1 - damping)
        ballVelocity.dy *= (1 - damping)

        ballVelocity = setMagnitude(ballVelocity, constantSpeed)

        var nextPos = CGPoint(x: ballPosition.x + ballVelocity.dx * dt,
                              y: ballPosition.y + ballVelocity.dy * dt)

        handleWallCollision(nextPos: &nextPos)
        handleBrickCollisions(nextPos: &nextPos)
        handleWallCollision(nextPos: &nextPos)
        handlePaddleCollision(nextPos: &nextPos)

        ballPosition = nextPos

        if bricks.allSatisfy({ !$0.isAlive }) && status == .running {
            endGame(won: true)
        }
    }

    // MARK: - Collisions

    private func handleWallCollision(nextPos: inout CGPoint) {
        let left = ballRadius + 2
        let right = worldSize.width - ballRadius - 2
        let top = ballRadius + 2
        let bottom = worldSize.height - ballRadius - 2

        var collided = false

        if nextPos.x < left {
            nextPos.x = left
            ballVelocity.dx = abs(ballVelocity.dx) * restitution
            collided = true
        } else if nextPos.x > right {
            nextPos.x = right
            ballVelocity.dx = -abs(ballVelocity.dx) * restitution
            collided = true
        }

        if nextPos.y < top {
            nextPos.y = top
            ballVelocity.dy = abs(ballVelocity.dy) * restitution
            collided = true
        } else if nextPos.y > bottom {
            loseLife()
            return
        }

        if collided {
            haptics.light()
            ballVelocity = setMagnitude(ballVelocity, constantSpeed)
            ballVelocity = clampDirection(ballVelocity)
        }
    }

    private func handlePaddleCollision(nextPos: inout CGPoint) {
        guard status == .running else { return }

        let paddleRect = CGRect(x: paddlePosition.x - paddleWidth / 2,
                                y: paddlePosition.y - paddleHeight / 2,
                                width: paddleWidth,
                                height: paddleHeight)

        if circleIntersectsRect(center: nextPos, radius: ballRadius, rect: paddleRect) && ballVelocity.dy > 0 {
            nextPos.y = paddleRect.minY - ballRadius - 0.5

            let normal = CGVector(dx: 0, dy: -1)
            let dot = ballVelocity.dx * normal.dx + ballVelocity.dy * normal.dy
            var reflected = CGVector(dx: ballVelocity.dx - 2 * dot * normal.dx,
                                     dy: ballVelocity.dy - 2 * dot * normal.dy)

            let relative = (nextPos.x - paddlePosition.x) / (paddleWidth / 2)
            let clamped = max(-1, min(1, relative))
            reflected.dx += tangentBoost * clamped * constantSpeed

            reflected = setMagnitude(reflected, constantSpeed * restitution)
            reflected = clampDirection(reflected)

            ballVelocity = reflected
            haptics.soft()
        }
    }

    private func handleBrickCollisions(nextPos: inout CGPoint) {
        guard status == .running else { return }

        for i in bricks.indices {
            if !bricks[i].isAlive { continue }
            let rect = bricks[i].rect
            if circleIntersectsRect(center: nextPos, radius: ballRadius, rect: rect) {
                let overlapLeft = (nextPos.x + ballRadius) - rect.minX
                let overlapRight = rect.maxX - (nextPos.x - ballRadius)
                let overlapTop = (nextPos.y + ballRadius) - rect.minY
                let overlapBottom = rect.maxY - (nextPos.y - ballRadius)

                let minOverlap = min(overlapLeft, overlapRight, overlapTop, overlapBottom)
                var normal = CGVector(dx: 0, dy: 0)

                if minOverlap == overlapLeft {
                    nextPos.x = rect.minX - ballRadius - 0.5
                    normal = CGVector(dx: -1, dy: 0)
                } else if minOverlap == overlapRight {
                    nextPos.x = rect.maxX + ballRadius + 0.5
                    normal = CGVector(dx: 1, dy: 0)
                } else if minOverlap == overlapTop {
                    nextPos.y = rect.minY - ballRadius - 0.5
                    normal = CGVector(dx: 0, dy: -1)
                } else {
                    nextPos.y = rect.maxY + ballRadius + 0.5
                    normal = CGVector(dx: 0, dy: 1)
                }

                let dot = ballVelocity.dx * normal.dx + ballVelocity.dy * normal.dy
                var reflected = CGVector(dx: ballVelocity.dx - 2 * dot * normal.dx,
                                         dy: ballVelocity.dy - 2 * dot * normal.dy)
                reflected = setMagnitude(reflected, constantSpeed * restitution)
                reflected = clampDirection(reflected)
                ballVelocity = reflected

                let separation: CGFloat = 0.75
                nextPos.x += normal.dx * separation
                nextPos.y += normal.dy * separation

                bricks[i].hitPoints -= 1
                if !bricks[i].isAlive {
                    score += bricks[i].score
                    haptics.success(light: true)
                } else {
                    haptics.light()
                }

                break
            }
        }
    }

    // MARK: - Lose Life
    private func loseLife() {
        guard status == .running else { return }
        lives -= 1
        haptics.warning()
        if lives <= 0 {
            endGame(won: false)
            return
        }
        status = .ready
        resetBallOnPaddle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if status == .ready { launchBall() }
        }
    }

    // MARK: - Geometry + Math helpers
    private func circleIntersectsRect(center: CGPoint, radius: CGFloat, rect: CGRect) -> Bool {
        let cx = max(rect.minX, min(center.x, rect.maxX))
        let cy = max(rect.minY, min(center.y, rect.maxY))
        let dx = center.x - cx
        let dy = center.y - cy
        return dx * dx + dy * dy <= radius * radius
    }

    private func normalize(_ v: CGVector) -> CGVector {
        let len = max(0.000001, sqrt(v.dx * v.dx + v.dy * v.dy))
        return CGVector(dx: v.dx / len, dy: v.dy / len)
    }

    private func magnitude(_ v: CGVector) -> CGFloat {
        sqrt(v.dx * v.dx + v.dy * v.dy)
    }

    private func setMagnitude(_ v: CGVector, _ m: CGFloat) -> CGVector {
        let n = normalize(v)
        return CGVector(dx: n.dx * m, dy: n.dy * m)
    }

    private func clampAngle(_ angle: CGFloat) -> CGFloat {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        if a > .pi { a -= .pi }
        let t = Swift.max(minAngle, Swift.min(maxAngle, a))
        return t
    }

    private func clampDirection(_ v: CGVector) -> CGVector {
        let speed = magnitude(v)
        var angle = atan2(v.dy, v.dx)
        let sign: CGFloat = angle >= 0 ? 1 : -1
        var absAngle = abs(angle)
        absAngle = Swift.max(minAngle, Swift.min(maxAngle, absAngle))
        angle = absAngle * sign
        return CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed)
    }
}

// MARK: - Brick rendering with material images (no cracks)

private struct BrickView: View {
    let brick: Brick

    var body: some View {
        Image(materialName(for: brick.color))
            .resizable()
            .scaledToFill()
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.white.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // Map color hue to material asset name: Wood / Stone / Iron
    private func materialName(for color: Color) -> String {
        #if canImport(UIKit)
        let uiColor = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            if h >= 0.5 && h <= 0.92 {
                return "Wood"   // 藍/紫
            } else if h >= 0.25 && h < 0.5 {
                return "Stone"  // 青/綠
            } else if h >= 0.08 && h < 0.25 {
                return h < 0.16 ? "Iron" : "Stone" // 黃→Iron，轉綠→Stone
            } else {
                return "Iron"   // 紅
            }
        }
        return "Iron"
        #else
        return "Iron"
        #endif
    }
}

// MARK: - Haptics

private final class Haptics {
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactSoft = UIImpactFeedbackGenerator(style: .soft)
    private let notif = UINotificationFeedbackGenerator()

    func light() { impactLight.impactOccurred() }
    func soft() { impactSoft.impactOccurred() }
    func warning() { notif.notificationOccurred(.warning) }
    func error() { notif.notificationOccurred(.error) }
    func success(light: Bool) {
        if light {
            impactLight.impactOccurred(intensity: 0.9)
        } else {
            notif.notificationOccurred(.success)
        }
    }
}

// MARK: - BGM Player

private final class BGMPlayer {
    static let shared = BGMPlayer()
    private var player: AVAudioPlayer?

    private init() {}

    func play(loop: Bool = true, volume: Float = 0.6) {
        // 檔名與副檔名請保持與專案內一致
        guard let url = Bundle.main.url(forResource: "太空音樂背景", withExtension: "mp3") else {
            print("BGM not found in bundle.")
            return
        }
        do {
            // 設定音訊類別，允許與其他聲音混音（避免打斷使用者的背景音樂）
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)

            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = loop ? -1 : 0
            player?.volume = volume
            player?.prepareToPlay()
            player?.play()
        } catch {
            print("BGMPlayer error: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    func setVolume(_ volume: Float, fadeDuration: TimeInterval = 0) {
        guard let player else { return }
        if fadeDuration > 0 {
            player.setVolume(volume, fadeDuration: fadeDuration)
        } else {
            player.volume = volume
        }
    }
}

#Preview {
    ContentView()
}
