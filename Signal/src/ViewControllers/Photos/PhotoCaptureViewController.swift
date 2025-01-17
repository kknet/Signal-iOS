//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import AVFoundation
import Foundation
import Lottie
import Photos
import UIKit
import SignalMessaging
import SignalUI

protocol PhotoCaptureViewControllerDelegate: AnyObject {
    func photoCaptureViewControllerDidFinish(_ photoCaptureViewController: PhotoCaptureViewController)
    func photoCaptureViewControllerDidCancel(_ photoCaptureViewController: PhotoCaptureViewController)
    func photoCaptureViewControllerDidTryToCaptureTooMany(_ photoCaptureViewController: PhotoCaptureViewController)
    func photoCaptureViewControllerViewWillAppear(_ photoCaptureViewController: PhotoCaptureViewController)
    func photoCaptureViewControllerCanCaptureMoreItems(_ photoCaptureViewController: PhotoCaptureViewController) -> Bool
    func photoCaptureViewControllerDidRequestPresentPhotoLibrary(_ photoCaptureViewController: PhotoCaptureViewController)
    func photoCaptureViewController(_ photoCaptureViewController: PhotoCaptureViewController,
                                    didRequestSwitchCaptureModeTo captureMode: PhotoCaptureViewController.CaptureMode,
                                    completion: @escaping (Bool) -> Void)
}

protocol PhotoCaptureViewControllerDataSource: AnyObject {
    var numberOfMediaItems: Int { get }
    func addMedia(attachment: SignalAttachment)
}

enum PhotoCaptureError: Error {
    case assertionError(description: String)
    case initializationFailed
    case captureFailed
    case invalidVideo
}

extension PhotoCaptureError: LocalizedError, UserErrorDescriptionProvider {
    var localizedDescription: String {
        switch self {
        case .initializationFailed:
            return NSLocalizedString("PHOTO_CAPTURE_UNABLE_TO_INITIALIZE_CAMERA", comment: "alert title")
        case .captureFailed:
            return NSLocalizedString("PHOTO_CAPTURE_UNABLE_TO_CAPTURE_IMAGE", comment: "alert title")
        case .assertionError, .invalidVideo:
            return NSLocalizedString("PHOTO_CAPTURE_GENERIC_ERROR", comment: "alert title, generic error preventing user from capturing a photo")
        }
    }
}

class PhotoCaptureViewController: OWSViewController, InteractiveDismissDelegate {

    weak var delegate: PhotoCaptureViewControllerDelegate?
    weak var dataSource: PhotoCaptureViewControllerDataSource?
    private var interactiveDismiss: PhotoCaptureInteractiveDismiss?

    public lazy var photoCapture = PhotoCapture()

    deinit {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        photoCapture.stopCapture().done {
            Logger.debug("stopCapture completed")
        }
    }

    // MARK: - Overrides

    override func loadView() {
        view = UIView()
        view.backgroundColor = Theme.darkThemeBackgroundColor
        view.preservesSuperviewLayoutMargins = true

        definesPresentationContext = true

        initializeUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupPhotoCapture()
        // If the view is already visible, setup the volume button listener
        // now that the capture UI is ready. Otherwise, we'll wait until
        // we're visible.
        if isVisible {
            VolumeButtons.shared?.addObserver(observer: photoCapture)
        }

        updateFlashModeControl(animated: false)

        view.addGestureRecognizer(pinchZoomGesture)
        view.addGestureRecognizer(tapToFocusGesture)
        view.addGestureRecognizer(doubleTapToSwitchCameraGesture)

        if let navController = self.navigationController {
            let interactiveDismiss = PhotoCaptureInteractiveDismiss(viewController: navController)
            interactiveDismiss.interactiveDismissDelegate = self
            interactiveDismiss.addGestureRecognizer(to: view)
            self.interactiveDismiss = interactiveDismiss
        }

        tapToFocusGesture.require(toFail: doubleTapToSwitchCameraGesture)

        bottomBar.photoLibraryButton.configure()
        if let sideBar = sideBar {
            sideBar.photoLibraryButton.configure()
        }
    }

    private var isVisible = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        delegate?.photoCaptureViewControllerViewWillAppear(self)

        isVisible = true
        let previewOrientation: AVCaptureVideoOrientation
        if UIDevice.current.isIPad {
            previewOrientation = AVCaptureVideoOrientation(interfaceOrientation: CurrentAppContext().interfaceOrientation)  ?? .portrait
        } else {
            previewOrientation = .portrait
        }
        UIViewController.attemptRotationToDeviceOrientation()
        photoCapture.updateVideoPreviewConnection(toOrientation: previewOrientation)
        updateIconOrientations(isAnimated: false, captureOrientation: previewOrientation)
        resumePhotoCapture()

        if let dataSource = dataSource, dataSource.numberOfMediaItems > 0 {
            captureMode = .multi
        }
        updateDoneButtonAppearance()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if hasCaptureStarted {
            BenchEventComplete(eventId: "Show-Camera")
            VolumeButtons.shared?.addObserver(observer: photoCapture)
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        isVisible = false
        VolumeButtons.shared?.removeObserver(photoCapture)
        pausePhotoCapture()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override var prefersStatusBarHidden: Bool {
        !UIDevice.current.hasIPhoneXNotch && !UIDevice.current.isIPad && !CurrentAppContext().hasActiveCall
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        if UIDevice.current.isIPad {
            // Since we support iPad multitasking, we cannot *disable* rotation of our views.
            // Rotating the preview layer is really distracting, so we fade out the preview layer
            // while the rotation occurs.
            self.previewView.alpha = 0
            coordinator.animate(alongsideTransition: { _ in },
                                completion: { _ in
                UIView.animate(withDuration: 0.1) {
                    self.previewView.alpha = 1
                }
            })
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        isIPadUIInRegularMode = traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular
    }

    // MARK: - Layout Code

    private var isIPadUIInRegularMode = false {
        didSet {
            guard oldValue != isIPadUIInRegularMode else { return }
            updateIPadInterfaceLayout()
        }
    }

    private var isRecordingVideo: Bool = false {
        didSet {
            if isRecordingVideo {
                topBar.mode = .videoRecording
                topBar.recordingTimerView.startCounting()

                let captureControlState: CameraCaptureControl.State = UIAccessibility.isVoiceOverRunning ? .recordingUsingVoiceOver : .recording
                bottomBar.captureControl.setState(captureControlState, animationDuration: 0.4)
                if let sideBar = sideBar {
                    sideBar.cameraCaptureControl.setState(captureControlState, animationDuration: 0.4)
                }
            } else {
                topBar.mode = isIPadUIInRegularMode ? .closeButton : .cameraControls
                topBar.recordingTimerView.stopCounting()

                bottomBar.captureControl.setState(.initial, animationDuration: 0.2)
                if let sideBar = sideBar {
                    sideBar.cameraCaptureControl.setState(.initial, animationDuration: 0.2)
                }
            }

            bottomBar.isRecordingVideo = isRecordingVideo
            if let sideBar = sideBar {
                sideBar.isRecordingVideo = isRecordingVideo
            }

            doneButton.isHidden = isRecordingVideo || doneButton.badgeNumber == 0
        }
    }

    func switchToMultiCaptureMode() {
        self.captureMode = .multi
    }

    enum CaptureMode {
        case single
        case multi
    }
    private(set) var captureMode: CaptureMode = .single {
        didSet {
            topBar.batchModeButton.setCaptureMode(captureMode, animated: true)
            if let sideBar = sideBar {
                sideBar.batchModeButton.setCaptureMode(captureMode, animated: true)
            }
        }
    }

    private let topBar = TopBar(frame: .zero)

    private let bottomBar = BottomBar(frame: .zero)
    private var bottomBarVerticalPositionConstraint: NSLayoutConstraint!

    private var frontCameraZoomControl: CameraZoomSelectionControl?
    private var rearCameraZoomControl: CameraZoomSelectionControl?
    private var cameraZoomControlIPhoneConstraints: [NSLayoutConstraint]?
    private var cameraZoomControlIPadConstraints: [NSLayoutConstraint]?

    private var sideBar: SideBar? // Optional because most devices are iPhones and will never need this.

    private lazy var tapToFocusView: AnimationView = {
        let view = AnimationView(name: "tap_to_focus")
        view.animationSpeed = 1
        view.backgroundBehavior = .forceFinish
        view.contentMode = .scaleAspectFit
        view.autoSetDimensions(to: CGSize(square: 150))
        view.setContentHuggingHigh()
        return view
    }()

    private var previewView: CapturePreviewView {
        return photoCapture.previewView
    }

    private lazy var doneButton: MediaDoneButton = {
        let button = MediaDoneButton(type: .custom)
        button.badgeNumber = 0
        button.userInterfaceStyleOverride = .dark
        return button
    }()
    private var doneButtonIPhoneConstraints: [NSLayoutConstraint]!
    private var doneButtonIPadConstraints: [NSLayoutConstraint]!

    private func initializeUI() {
        // Step 1. Initialize all UI elements for iPhone layout (which can also be used on an iPad).

        view.addSubview(previewView)

        view.addSubview(topBar)
        topBar.mode = .cameraControls
        topBar.closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        topBar.batchModeButton.addTarget(self, action: #selector(didTapBatchMode), for: .touchUpInside)
        topBar.flashModeButton.addTarget(self, action: #selector(didTapFlashMode), for: .touchUpInside)
        topBar.autoPinWidthToSuperview()
        if UIDevice.current.isIPad {
            topBar.autoPinEdge(toSuperviewSafeArea: .top)
        } else {
            // This constraint produces result visually identical to layout implemented in MediaTopBar.install(in:).
            // MediaTopBar.install(in:) can't be used here because attaching to the top safe area
            // would yield incorrect layout during interactive dismiss.
            topBar.autoPinEdge(.top, to: .top, of: previewView)
        }

        view.addSubview(bottomBar)
        bottomBar.isCompactHeightLayout = !UIDevice.current.hasIPhoneXNotch
        bottomBar.switchCameraButton.addTarget(self, action: #selector(didTapSwitchCamera), for: .touchUpInside)
        bottomBar.photoLibraryButton.addTarget(self, action: #selector(didTapPhotoLibrary), for: .touchUpInside)
        bottomBar.autoPinWidthToSuperview()
        if bottomBar.isCompactHeightLayout {
            // On devices with home button bar is simply pinned to the bottom of the screen
            // with a margin that defines space under the shutter button.
            view.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: 32).isActive = true
        } else {
            // On `notch` devices:
            //  i. Shutter button is placed 16 pts above the bottom edge of the preview view.
            previewView.bottomAnchor.constraint(equalTo: bottomBar.shutterButtonLayoutGuide.bottomAnchor, constant: 16).isActive = true

            //  ii. Other buttons are centered vertically in the black box between
            //      bottom of the preview view and top of bottom safe area.
            bottomBarVerticalPositionConstraint = bottomBar.controlButtonsLayoutGuide.centerYAnchor.constraint(equalTo: previewView.bottomAnchor)
            view.addConstraint(bottomBarVerticalPositionConstraint)
        }

        cameraZoomControlIPhoneConstraints = []

        let availableFrontCameras = photoCapture.cameraZoomFactorMap(forPosition: .front)
        if availableFrontCameras.count > 0 {
            let cameras = availableFrontCameras.sorted { $0.0 < $1.0 }.map { ($0.0, $0.1) }

            let cameraZoomControl = CameraZoomSelectionControl(availableCameras: cameras)
            cameraZoomControl.delegate = self
            view.addSubview(cameraZoomControl)
            self.frontCameraZoomControl = cameraZoomControl

            let cameraZoomControlConstraints =
            [ cameraZoomControl.centerXAnchor.constraint(equalTo: bottomBar.shutterButtonLayoutGuide.centerXAnchor),
              cameraZoomControl.bottomAnchor.constraint(equalTo: bottomBar.shutterButtonLayoutGuide.topAnchor, constant: -32) ]
            view.addConstraints(cameraZoomControlConstraints)
            cameraZoomControlIPhoneConstraints?.append(contentsOf: cameraZoomControlConstraints)
        }

        let availableRearCameras = photoCapture.cameraZoomFactorMap(forPosition: .back)
        if availableRearCameras.count > 0 {
            let cameras = availableRearCameras.sorted { $0.0 < $1.0 }.map { ($0.0, $0.1) }

            let cameraZoomControl = CameraZoomSelectionControl(availableCameras: cameras)
            cameraZoomControl.delegate = self
            view.addSubview(cameraZoomControl)
            self.rearCameraZoomControl = cameraZoomControl

            let cameraZoomControlConstraints =
            [ cameraZoomControl.centerXAnchor.constraint(equalTo: bottomBar.shutterButtonLayoutGuide.centerXAnchor),
              cameraZoomControl.bottomAnchor.constraint(equalTo: bottomBar.shutterButtonLayoutGuide.topAnchor, constant: -32) ]
            view.addConstraints(cameraZoomControlConstraints)
            cameraZoomControlIPhoneConstraints?.append(contentsOf: cameraZoomControlConstraints)
        }
        updateUIOnCameraPositionChange()

        view.addSubview(doneButton)
        doneButton.isHidden = true
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButtonIPhoneConstraints = [ doneButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
                                        doneButton.centerYAnchor.constraint(equalTo: bottomBar.shutterButtonLayoutGuide.centerYAnchor) ]
        view.addConstraints(doneButtonIPhoneConstraints)
        doneButton.addTarget(self, action: #selector(didTapDoneButton), for: .touchUpInside)

        view.addSubview(tapToFocusView)
        tapToFocusView.isUserInteractionEnabled = false
        tapToFocusLeftConstraint = tapToFocusView.centerXAnchor.constraint(equalTo: view.leftAnchor)
        tapToFocusLeftConstraint.isActive = true
        tapToFocusTopConstraint = tapToFocusView.centerYAnchor.constraint(equalTo: view.topAnchor)
        tapToFocusTopConstraint.isActive = true

        // Step 2. Check if we're running on an iPad and update UI accordingly.
        // Note that `traitCollectionDidChange` won't be called during initial view loading process.
        isIPadUIInRegularMode = traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular

        // This background footer doesn't let view controller underneath current VC
        // to be visible at the bottom of the screen during interactive dismiss.
        if UIDevice.current.hasIPhoneXNotch {
            let blackFooter = UIView()
            blackFooter.backgroundColor = view.backgroundColor
            view.insertSubview(blackFooter, at: 0)
            blackFooter.autoPinWidthToSuperview()
            blackFooter.autoPinEdge(toSuperviewEdge: .bottom)
            blackFooter.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5).isActive = true
        }
    }

    private func initializeIPadSpecificUIIfNecessary() {
        guard sideBar == nil else { return }

        let sideBar = SideBar(frame: .zero)
        sideBar.cameraCaptureControl.delegate = photoCapture
        sideBar.batchModeButton.addTarget(self, action: #selector(didTapBatchMode), for: .touchUpInside)
        sideBar.flashModeButton.addTarget(self, action: #selector(didTapFlashMode), for: .touchUpInside)
        sideBar.switchCameraButton.addTarget(self, action: #selector(didTapSwitchCamera), for: .touchUpInside)
        sideBar.photoLibraryButton.addTarget(self, action: #selector(didTapPhotoLibrary), for: .touchUpInside)
        view.addSubview(sideBar)
        sideBar.autoPinTrailingToSuperviewMargin(withInset: 12)
        sideBar.cameraCaptureControl.shutterButtonLayoutGuide.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        self.sideBar = sideBar

        sideBar.batchModeButton.setImage(topBar.batchModeButton.image(for: .normal), for: .normal)
        updateFlashModeControl(animated: false)

        doneButtonIPadConstraints = [ doneButton.centerXAnchor.constraint(equalTo: sideBar.centerXAnchor),
                                      doneButton.bottomAnchor.constraint(equalTo: sideBar.topAnchor, constant: -8)]

        cameraZoomControlIPadConstraints = []
        if let cameraZoomControl = frontCameraZoomControl {
            let constraints = [ cameraZoomControl.centerYAnchor.constraint(equalTo: sideBar.cameraCaptureControl.shutterButtonLayoutGuide.centerYAnchor),
                                cameraZoomControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32)]
            cameraZoomControlIPadConstraints?.append(contentsOf: constraints)
        }
        if let cameraZoomControl = rearCameraZoomControl {
            let constraints = [ cameraZoomControl.centerYAnchor.constraint(equalTo: sideBar.cameraCaptureControl.shutterButtonLayoutGuide.centerYAnchor),
                                cameraZoomControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32)]
            cameraZoomControlIPadConstraints?.append(contentsOf: constraints)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        guard !(interactiveDismiss?.interactionInProgress ?? false) else { return }

        // Clamp capture view to 16:9 on iPhones.
        var previewFrame = view.bounds
        var cornerRadius: CGFloat = 0
        if !UIDevice.current.isIPad {
            let targetAspectRatio: CGFloat = 16/9
            let currentAspectRatio: CGFloat = previewFrame.height / previewFrame.width

            if abs(currentAspectRatio - targetAspectRatio) > 0.001 {
                previewFrame.y = view.safeAreaInsets.top
                previewFrame.height = previewFrame.width * targetAspectRatio
                cornerRadius = 18
            }
        }
        previewView.frame = previewFrame
        previewView.previewLayer.cornerRadius = cornerRadius

        // See comment in `initializeUI`.
        if !bottomBar.isCompactHeightLayout {
            let blackBarHeight = view.bounds.maxY - previewFrame.maxY - view.safeAreaInsets.bottom
            bottomBarVerticalPositionConstraint.constant = 0.5 * blackBarHeight
        }
    }

    private func updateIPadInterfaceLayout() {
        owsAssertDebug(UIDevice.current.isIPad)

        if isIPadUIInRegularMode {
            initializeIPadSpecificUIIfNecessary()

            view.removeConstraints(doneButtonIPhoneConstraints)
            view.addConstraints(doneButtonIPadConstraints)
        } else {
            view.removeConstraints(doneButtonIPadConstraints)
            view.addConstraints(doneButtonIPhoneConstraints)
        }

        if let cameraZoomControl = frontCameraZoomControl {
            cameraZoomControl.axis = isIPadUIInRegularMode ? .vertical : .horizontal
        }
        if let cameraZoomControl = rearCameraZoomControl {
            cameraZoomControl.axis = isIPadUIInRegularMode ? .vertical : .horizontal
        }
        if let iPhoneConstraints = cameraZoomControlIPhoneConstraints,
           let iPadConstraints = cameraZoomControlIPadConstraints {
            if isIPadUIInRegularMode {
                view.removeConstraints(iPhoneConstraints)
                view.addConstraints(iPadConstraints)
            } else {
                view.removeConstraints(iPadConstraints)
                view.addConstraints(iPhoneConstraints)
            }
        }

        if !isRecordingVideo {
            topBar.mode = isIPadUIInRegularMode ? .closeButton : .cameraControls
        }
        bottomBar.isHidden = isIPadUIInRegularMode
        sideBar?.isHidden = !isIPadUIInRegularMode
    }

    func updateDoneButtonAppearance() {
        if captureMode == .multi, let badgeNumber = dataSource?.numberOfMediaItems, badgeNumber > 0 {
            doneButton.badgeNumber = badgeNumber
            doneButton.isHidden = false
        } else {
            doneButton.isHidden = true
        }
        if bottomBar.isCompactHeightLayout {
            bottomBar.switchCameraButton.isHidden = !doneButton.isHidden
        }
    }

    private func updateUIOnCameraPositionChange(animated: Bool = false) {
        let isFrontCamera = photoCapture.desiredPosition == .front
        frontCameraZoomControl?.setIsHidden(!isFrontCamera, animated: animated)
        rearCameraZoomControl?.setIsHidden(isFrontCamera, animated: animated)
        bottomBar.switchCameraButton.isFrontCameraActive = isFrontCamera
        if let sideBar = sideBar {
            sideBar.switchCameraButton.isFrontCameraActive = isFrontCamera
        }
    }

    // MARK: - Interactive Dismiss

    func interactiveDismissDidBegin(_ interactiveDismiss: UIPercentDrivenInteractiveTransition) {
        view.backgroundColor = .clear
    }

    func interactiveDismissDidFinish(_ interactiveDismiss: UIPercentDrivenInteractiveTransition) {
        dismiss(animated: true)
    }

    func interactiveDismissDidCancel(_ interactiveDismiss: UIPercentDrivenInteractiveTransition) {
        view.backgroundColor = Theme.darkThemeBackgroundColor
    }

    // MARK: - Gestures

    lazy var pinchZoomGesture: UIPinchGestureRecognizer = {
        return UIPinchGestureRecognizer(target: self, action: #selector(didPinchZoom(pinchGesture:)))
    }()

    lazy var tapToFocusGesture: UITapGestureRecognizer = {
        return UITapGestureRecognizer(target: self, action: #selector(didTapFocusExpose(tapGesture:)))
    }()

    lazy var doubleTapToSwitchCameraGesture: UITapGestureRecognizer = {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(didDoubleTapToSwitchCamera(tapGesture:)))
        tapGesture.numberOfTapsRequired = 2
        return tapGesture
    }()

    // MARK: - Events

    @objc
    func didTapClose() {
        delegate?.photoCaptureViewControllerDidCancel(self)
    }

    @objc
    func didTapSwitchCamera() {
        switchCameraPosition()
    }

    @objc
    func didDoubleTapToSwitchCamera(tapGesture: UITapGestureRecognizer) {
        guard !isRecordingVideo else {
            // - Orientation gets out of sync when switching cameras mid movie.
            // - Audio gets out of sync when switching cameras mid movie
            // https://stackoverflow.com/questions/13951182/audio-video-out-of-sync-after-switch-camera
            return
        }

        let tapLocation = tapGesture.location(in: view)
        guard let tapView = view.hitTest(tapLocation, with: nil), tapView == previewView else {
            return
        }

        switchCameraPosition()
    }

    private func switchCameraPosition() {
        if let switchCameraButton = isIPadUIInRegularMode ? sideBar?.switchCameraButton : bottomBar.switchCameraButton {
            switchCameraButton.performSwitchAnimation()
        }
        photoCapture.switchCameraPosition().done { [weak self] in
            self?.updateUIOnCameraPositionChange(animated: true)
        }.catch { error in
            self.showFailureUI(error: error)
        }
    }

    @objc
    func didTapFlashMode() {
        firstly {
            photoCapture.switchFlashMode()
        }.done {
            self.updateFlashModeControl(animated: true)
        }.catch { error in
            owsFailDebug("Error: \(error)")
        }
    }

    @objc
    func didTapBatchMode() {
        guard let delegate = delegate else {
            return
        }
        let targetMode: CaptureMode = {
            switch captureMode {
            case .single: return .multi
            case .multi: return .single
            }
        }()
        delegate.photoCaptureViewController(self, didRequestSwitchCaptureModeTo: targetMode) { approved in
            if approved {
                self.captureMode = targetMode
                self.updateDoneButtonAppearance()
            }
        }
    }

    @objc
    func didTapPhotoLibrary() {
        delegate?.photoCaptureViewControllerDidRequestPresentPhotoLibrary(self)
    }

    @objc
    func didTapDoneButton() {
        delegate?.photoCaptureViewControllerDidFinish(self)
    }

    @objc
    func didPinchZoom(pinchGesture: UIPinchGestureRecognizer) {
        switch pinchGesture.state {
        case .began:
            photoCapture.beginPinchZoom()
            fallthrough
        case .changed:
            photoCapture.updatePinchZoom(withScale: pinchGesture.scale)
        case .ended:
            photoCapture.completePinchZoom(withScale: pinchGesture.scale)
        default:
            break
        }
    }

    @objc
    func didTapFocusExpose(tapGesture: UITapGestureRecognizer) {
        guard previewView.bounds.contains(tapGesture.location(in: previewView)) else {
            return
        }

        let viewLocation = tapGesture.location(in: previewView)
        let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: viewLocation)
        photoCapture.focus(with: .autoFocus, exposureMode: .autoExpose, at: devicePoint, monitorSubjectAreaChange: true)

        lastUserFocusTapPoint = devicePoint
        do {
            let focusFrameSuperview = tapToFocusView.superview!
            positionTapToFocusView(center: tapGesture.location(in: focusFrameSuperview))
            focusFrameSuperview.layoutIfNeeded()
            startFocusAnimation()
        }
    }

    // MARK: - Focus Animations

    private var tapToFocusLeftConstraint: NSLayoutConstraint!
    private var tapToFocusTopConstraint: NSLayoutConstraint!
    private var lastUserFocusTapPoint: CGPoint?

    private func positionTapToFocusView(center: CGPoint) {
        tapToFocusLeftConstraint.constant = center.x
        tapToFocusTopConstraint.constant = center.y
    }

    private func startFocusAnimation() {
        tapToFocusView.stop()
        tapToFocusView.play(fromProgress: 0.0, toProgress: 0.9)
    }

    private func completeFocusAnimation(forFocusPoint focusPoint: CGPoint) {
        guard let lastUserFocusTapPoint = lastUserFocusTapPoint else { return }

        guard lastUserFocusTapPoint.within(0.005, of: focusPoint) else {
            Logger.verbose("focus completed for obsolete focus point. User has refocused.")
            return
        }

        tapToFocusView.play(toProgress: 1.0)
    }

    // MARK: - Orientation

    private func updateIconOrientations(isAnimated: Bool, captureOrientation: AVCaptureVideoOrientation) {
        guard !UIDevice.current.isIPad else { return }

        Logger.verbose("captureOrientation: \(captureOrientation)")

        let transformFromOrientation: CGAffineTransform
        switch captureOrientation {
        case .portrait:
            transformFromOrientation = .identity
        case .portraitUpsideDown:
            transformFromOrientation = CGAffineTransform(rotationAngle: .pi)
        case .landscapeRight:
            transformFromOrientation = CGAffineTransform(rotationAngle: .halfPi)
        case .landscapeLeft:
            transformFromOrientation = CGAffineTransform(rotationAngle: -1 * .halfPi)
        @unknown default:
            owsFailDebug("unexpected captureOrientation: \(captureOrientation.rawValue)")
            transformFromOrientation = .identity
        }

        // Don't "unrotate" the switch camera icon if the front facing camera had been selected.
        let tranformFromCameraType: CGAffineTransform = photoCapture.desiredPosition == .front ? CGAffineTransform(rotationAngle: -.pi) : .identity

        var buttonsToUpdate: [UIView] = [ topBar.batchModeButton, topBar.flashModeButton, bottomBar.photoLibraryButton ]
        if let cameraZoomControl = frontCameraZoomControl {
            buttonsToUpdate.append(contentsOf: cameraZoomControl.cameraZoomLevelIndicators)
        }
        if let cameraZoomControl = rearCameraZoomControl {
            buttonsToUpdate.append(contentsOf: cameraZoomControl.cameraZoomLevelIndicators)
        }
        let updateOrientation = {
            buttonsToUpdate.forEach { $0.transform = transformFromOrientation }
            self.bottomBar.switchCameraButton.transform = transformFromOrientation.concatenating(tranformFromCameraType)
        }

        if isAnimated {
            UIView.animate(withDuration: 0.3, animations: updateOrientation)
        } else {
            updateOrientation()
        }
    }

    // MARK: - Photo Capture

    var hasCaptureStarted = false

    private func captureReady() {
        self.hasCaptureStarted = true
        BenchEventComplete(eventId: "Show-Camera")
        if isVisible {
            VolumeButtons.shared?.addObserver(observer: photoCapture)
        }
    }

    private func setupPhotoCapture() {
        photoCapture.delegate = self
        bottomBar.captureControl.delegate = photoCapture
        if let sideBar = sideBar {
            sideBar.cameraCaptureControl.delegate = photoCapture
        }

        // If the session is already running, we're good to go.
        guard !photoCapture.session.isRunning else {
            return self.captureReady()
        }

        firstly {
            photoCapture.prepareVideoCapture()
        }.catch { [weak self] error in
            guard let self = self else { return }
            self.showFailureUI(error: error)
        }
    }

    private func pausePhotoCapture() {
        guard photoCapture.session.isRunning else { return }
        firstly {
            photoCapture.stopCapture()
        }.done { [weak self] in
            self?.hasCaptureStarted = false
        }.catch { [weak self] error in
            self?.showFailureUI(error: error)
        }
    }

    private func resumePhotoCapture() {
        guard !photoCapture.session.isRunning else { return }
        firstly {
            photoCapture.resumeCapture()
        }.done { [weak self] in
            self?.captureReady()
        }.catch { [weak self] error in
            self?.showFailureUI(error: error)
        }
    }

    private func showFailureUI(error: Error) {
        Logger.error("error: \(error)")

        OWSActionSheets.showActionSheet(title: nil,
                                        message: error.userErrorDescription,
                                        buttonTitle: CommonStrings.dismissButton,
                                        buttonAction: { [weak self] _ in self?.dismiss(animated: true) })
    }

    private func updateFlashModeControl(animated: Bool) {
        topBar.flashModeButton.setFlashMode(photoCapture.flashMode, animated: animated)
        if let sideBar = sideBar {
            sideBar.flashModeButton.setFlashMode(photoCapture.flashMode, animated: animated)
        }
    }
}

extension PhotoCaptureViewController: CameraZoomSelectionControlDelegate {

    fileprivate func cameraZoomControl(_ cameraZoomControl: CameraZoomSelectionControl, didSelect camera: PhotoCapture.CameraType) {
        let position: AVCaptureDevice.Position = cameraZoomControl == frontCameraZoomControl ? .front : .back
        photoCapture.switchCamera(to: camera, at: position, animated: true)
    }

    fileprivate func cameraZoomControl(_ cameraZoomControl: CameraZoomSelectionControl, didChangeZoomFactor zoomFactor: CGFloat) {
        photoCapture.changeVisibleZoomFactor(to: zoomFactor, animated: true)
    }
}

private class TopBar: MediaTopBar {

    let closeButton = RoundMediaButton(image: UIImage(named: "media-composer-close"), backgroundStyle: .blur)

    private let cameraControlsContainerView: UIStackView
    let flashModeButton = FlashModeButton()
    let batchModeButton = CaptureModeButton()

    let recordingTimerView = RecordingTimerView(frame: .zero)

    override init(frame: CGRect) {
        cameraControlsContainerView = UIStackView(arrangedSubviews: [ batchModeButton, flashModeButton ])

        super.init(frame: frame)

        closeButton.accessibilityLabel = NSLocalizedString("CAMERA_VO_CLOSE_BUTTON",
                                                           comment: "VoiceOver label for close (X) button in camera.")

        addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.layoutMarginsGuide.leadingAnchor.constraint(equalTo: controlsLayoutGuide.leadingAnchor).isActive = true
        closeButton.topAnchor.constraint(equalTo: controlsLayoutGuide.topAnchor).isActive = true
        closeButton.bottomAnchor.constraint(equalTo: controlsLayoutGuide.bottomAnchor).isActive = true

        addSubview(recordingTimerView)
        recordingTimerView.translatesAutoresizingMaskIntoConstraints = false
        recordingTimerView.centerYAnchor.constraint(equalTo: controlsLayoutGuide.centerYAnchor).isActive = true
        recordingTimerView.centerXAnchor.constraint(equalTo: controlsLayoutGuide.centerXAnchor).isActive = true

        cameraControlsContainerView.spacing = 0
        addSubview(cameraControlsContainerView)
        cameraControlsContainerView.translatesAutoresizingMaskIntoConstraints = false
        cameraControlsContainerView.topAnchor.constraint(equalTo: controlsLayoutGuide.topAnchor).isActive = true
        cameraControlsContainerView.bottomAnchor.constraint(equalTo: controlsLayoutGuide.bottomAnchor).isActive = true
        flashModeButton.layoutMarginsGuide.trailingAnchor.constraint(equalTo: controlsLayoutGuide.trailingAnchor).isActive = true
    }

    @available(*, unavailable, message: "Use init(frame:) instead")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Mode

    enum Mode {
        case cameraControls, closeButton, videoRecording
    }

    var mode: Mode = .cameraControls {
        didSet {
            switch mode {
            case .cameraControls:
                closeButton.isHidden = false
                cameraControlsContainerView.isHidden = false
                recordingTimerView.isHidden = true

            case .closeButton:
                closeButton.isHidden = false
                cameraControlsContainerView.isHidden = true
                recordingTimerView.isHidden = true

            case .videoRecording:
                closeButton.isHidden = true
                cameraControlsContainerView.isHidden = true
                recordingTimerView.isHidden = false
            }
        }
    }
}

private class BottomBar: UIView {

    private var compactHeightLayoutConstraints = [NSLayoutConstraint]()
    private var regularHeightLayoutConstraints = [NSLayoutConstraint]()
    var isCompactHeightLayout = false {
        didSet {
            guard oldValue != isCompactHeightLayout else { return }
            updateCompactHeightLayoutConstraints()
        }
    }

    var isRecordingVideo = false {
        didSet {
            photoLibraryButton.isHidden = isRecordingVideo
            switchCameraButton.isHidden = isRecordingVideo
        }
    }

    let photoLibraryButton = MediaPickerThumbnailButton()
    let switchCameraButton = CameraChooserButton(backgroundStyle: .solid(RoundMediaButton.defaultBackgroundColor))
    let controlButtonsLayoutGuide = UILayoutGuide() // area encompassing Photo Library and Switch Camera buttons.

    let captureControl = CameraCaptureControl(axis: .horizontal)
    var shutterButtonLayoutGuide: UILayoutGuide {
        captureControl.shutterButtonLayoutGuide
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        preservesSuperviewLayoutMargins = true

        addLayoutGuide(controlButtonsLayoutGuide)
        addConstraints([ controlButtonsLayoutGuide.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
                         controlButtonsLayoutGuide.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor) ])

        captureControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captureControl)
        captureControl.autoPinTopToSuperviewMargin()
        captureControl.autoPinTrailingToSuperviewMargin()
        addConstraint(captureControl.shutterButtonLayoutGuide.centerXAnchor.constraint(equalTo: centerXAnchor))

        photoLibraryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(photoLibraryButton)
        addConstraints([ photoLibraryButton.layoutMarginsGuide.leadingAnchor.constraint(equalTo: controlButtonsLayoutGuide.leadingAnchor),
                         photoLibraryButton.centerYAnchor.constraint(equalTo: controlButtonsLayoutGuide.centerYAnchor),
                         photoLibraryButton.topAnchor.constraint(greaterThanOrEqualTo: controlButtonsLayoutGuide.topAnchor) ])

        switchCameraButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(switchCameraButton)
        addConstraints([ switchCameraButton.layoutMarginsGuide.trailingAnchor.constraint(equalTo: controlButtonsLayoutGuide.trailingAnchor),
                         switchCameraButton.topAnchor.constraint(greaterThanOrEqualTo: controlButtonsLayoutGuide.topAnchor),
                         switchCameraButton.centerYAnchor.constraint(equalTo: controlButtonsLayoutGuide.centerYAnchor) ])

        compactHeightLayoutConstraints.append(contentsOf: [ controlButtonsLayoutGuide.centerYAnchor.constraint(equalTo: captureControl.shutterButtonLayoutGuide.centerYAnchor),
                                                            captureControl.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor) ])

        regularHeightLayoutConstraints.append(contentsOf: [ controlButtonsLayoutGuide.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
                                                            captureControl.bottomAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.bottomAnchor) ])

        updateCompactHeightLayoutConstraints()
    }

    @available(*, unavailable, message: "Use init(frame:) instead")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateCompactHeightLayoutConstraints() {
        if isCompactHeightLayout {
            removeConstraints(regularHeightLayoutConstraints)
            addConstraints(compactHeightLayoutConstraints)
        } else {
            removeConstraints(compactHeightLayoutConstraints)
            addConstraints(regularHeightLayoutConstraints)
        }
    }
}

private class SideBar: UIView {

    var isRecordingVideo = false {
        didSet {
            cameraControlsContainerView.isHidden = isRecordingVideo
            photoLibraryButton.isHidden = isRecordingVideo
        }
    }

    private let cameraControlsContainerView: UIStackView
    let flashModeButton = FlashModeButton()
    let batchModeButton = CaptureModeButton()
    let switchCameraButton = CameraChooserButton(backgroundStyle: .blur)

    let photoLibraryButton = MediaPickerThumbnailButton()

    private(set) var cameraCaptureControl = CameraCaptureControl(axis: .vertical)

    override init(frame: CGRect) {
        cameraControlsContainerView = UIStackView(arrangedSubviews: [ batchModeButton, flashModeButton, switchCameraButton ])

        super.init(frame: frame)

        layoutMargins = UIEdgeInsets(margin: 8)

        cameraControlsContainerView.spacing = 8
        cameraControlsContainerView.axis = .vertical
        addSubview(cameraControlsContainerView)
        cameraControlsContainerView.autoPinWidthToSuperviewMargins()
        cameraControlsContainerView.autoPinTopToSuperviewMargin()

        addSubview(cameraCaptureControl)
        cameraCaptureControl.autoHCenterInSuperview()
        cameraCaptureControl.shutterButtonLayoutGuide.topAnchor.constraint(equalTo: cameraControlsContainerView.bottomAnchor, constant: 24).isActive = true

        addSubview(photoLibraryButton)
        photoLibraryButton.autoHCenterInSuperview()
        photoLibraryButton.topAnchor.constraint(equalTo: cameraCaptureControl.shutterButtonLayoutGuide.bottomAnchor, constant: 24).isActive = true
        photoLibraryButton.bottomAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.bottomAnchor).isActive = true
    }

    @available(*, unavailable, message: "Use init(frame:) instead")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension PhotoCaptureViewController: PhotoCaptureDelegate {

    // MARK: - Photo

    func photoCaptureDidStart(_ photoCapture: PhotoCapture) {
        let captureFeedbackView = UIView()
        captureFeedbackView.backgroundColor = .black
        view.insertSubview(captureFeedbackView, aboveSubview: previewView)
        captureFeedbackView.autoPinEdgesToSuperviewEdges()

        // Ensure the capture feedback is laid out before we remove it,
        // depending on where we're coming from a layout pass might not
        // trigger in 0.05 seconds otherwise.
        view.setNeedsLayout()
        view.layoutIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            captureFeedbackView.removeFromSuperview()
        }
    }

    func photoCapture(_ photoCapture: PhotoCapture, didFinishProcessing attachment: SignalAttachment) {
        dataSource?.addMedia(attachment: attachment)

        updateDoneButtonAppearance()

        if captureMode == .multi {
            resumePhotoCapture()
        } else {
            delegate?.photoCaptureViewControllerDidFinish(self)
        }
    }

    func photoCapture(_ photoCapture: PhotoCapture, didFailProcessing error: Error) {
        isRecordingVideo = false

        if case PhotoCaptureError.invalidVideo = error {
            // Don't show an error if the user aborts recording before video
            // recording has begun.
            return
        }
        showFailureUI(error: error)
    }

    func photoCaptureCanCaptureMoreItems(_ photoCapture: PhotoCapture) -> Bool {
        return delegate?.photoCaptureViewControllerCanCaptureMoreItems(self) ?? false
    }

    func photoCaptureDidTryToCaptureTooMany(_ photoCapture: PhotoCapture) {
        delegate?.photoCaptureViewControllerDidTryToCaptureTooMany(self)
    }

    // MARK: - Video

    func photoCaptureWillBeginRecording(_ photoCapture: PhotoCapture) {
        Logger.verbose("")
        isRecordingVideo = true
    }

    func photoCaptureDidBeginRecording(_ photoCapture: PhotoCapture) {
        Logger.verbose("")
    }

    func photoCaptureDidFinishRecording(_ photoCapture: PhotoCapture) {
        Logger.verbose("")
        isRecordingVideo = false
    }

    func photoCaptureDidCancelRecording(_ photoCapture: PhotoCapture) {
        Logger.verbose("")
        isRecordingVideo = false
    }

    // MARK: -

    var zoomScaleReferenceDistance: CGFloat? {
        if isIPadUIInRegularMode {
            return previewView.bounds.width / 2
        }
        return previewView.bounds.height / 2
    }

    func photoCapture(_ photoCapture: PhotoCapture, didChangeVideoZoomFactor zoomFactor: CGFloat, forCameraPosition position: AVCaptureDevice.Position) {
        guard let cameraZoomControl = position == .front ? frontCameraZoomControl : rearCameraZoomControl else { return }
        cameraZoomControl.currentZoomFactor = zoomFactor
    }

    func beginCaptureButtonAnimation(_ duration: TimeInterval) {
        bottomBar.captureControl.setState(.recording, animationDuration: duration)
        if let sideBar = sideBar {
            sideBar.cameraCaptureControl.setState(.recording, animationDuration: duration)
        }
    }

    func endCaptureButtonAnimation(_ duration: TimeInterval) {
        bottomBar.captureControl.setState(.initial, animationDuration: duration)
        if let sideBar = sideBar {
            sideBar.cameraCaptureControl.setState(.initial, animationDuration: duration)
        }
    }

    func photoCapture(_ photoCapture: PhotoCapture, didChangeOrientation orientation: AVCaptureVideoOrientation) {
        updateIconOrientations(isAnimated: true, captureOrientation: orientation)
        if UIDevice.current.isIPad {
            photoCapture.updateVideoPreviewConnection(toOrientation: orientation)
        }
    }

    func photoCapture(_ photoCapture: PhotoCapture, didCompleteFocusing focusPoint: CGPoint) {
        completeFocusAnimation(forFocusPoint: focusPoint)
    }
}

// MARK: - Views

private class FlashModeButton: RoundMediaButton {

    private static let flashOn = UIImage(named: "media-composer-flash-filled")
    private static let flashOff = UIImage(named: "media-composer-flash-outline")
    private static let flashAuto = UIImage(named: "media-composer-flash-auto")

    private var flashMode: AVCaptureDevice.FlashMode = .auto

    required init() {
        super.init(image: FlashModeButton.flashAuto, backgroundStyle: .blur)
    }

    required init(image: UIImage?, backgroundStyle: RoundMediaButton.BackgroundStyle) {
        fatalError("init(image:backgroundStyle:) has not been implemented")
    }

    func setFlashMode(_ flashMode: AVCaptureDevice.FlashMode, animated: Bool) {
        guard self.flashMode != flashMode else { return }

        let image: UIImage? = {
            switch flashMode {
            case .auto:
                return FlashModeButton.flashAuto
            case .on:
                return FlashModeButton.flashOn
            case .off:
                return FlashModeButton.flashOff
            @unknown default:
                owsFailDebug("unexpected photoCapture.flashMode: \(flashMode.rawValue)")
                return FlashModeButton.flashAuto
            }
        }()
        setImage(image, animated: animated)
        self.flashMode = flashMode
    }
}

private class CameraChooserButton: RoundMediaButton {

    var isFrontCameraActive = false

    required init(backgroundStyle: RoundMediaButton.BackgroundStyle) {
        super.init(image: UIImage(named: "media-composer-switch-camera"), backgroundStyle: backgroundStyle)
    }

    required init(image: UIImage?, backgroundStyle: RoundMediaButton.BackgroundStyle) {
        fatalError("init(image:backgroundStyle:) has not been implemented")
    }

    func performSwitchAnimation() {
        UIView.animate(withDuration: 0.2) {
            let epsilonToForceCounterClockwiseRotation: CGFloat = 0.00001
            self.transform = self.transform.rotate(.pi + epsilonToForceCounterClockwiseRotation)
        }
    }
}

private class CaptureModeButton: RoundMediaButton {

    private static let batchModeOn = UIImage(named: "media-composer-create-album-solid")
    private static let batchModeOff = UIImage(named: "media-composer-create-album-outline")

    required init() {
        super.init(image: CaptureModeButton.batchModeOff, backgroundStyle: .blur)
    }

    required init(image: UIImage?, backgroundStyle: RoundMediaButton.BackgroundStyle) {
        fatalError("init(image:backgroundStyle:) has not been implemented")
    }

    private var captureMode = PhotoCaptureViewController.CaptureMode.single

    func setCaptureMode(_ captureMode: PhotoCaptureViewController.CaptureMode, animated: Bool) {
        guard self.captureMode != captureMode else { return }

        let image: UIImage? = {
            switch captureMode {
            case .single:
                return CaptureModeButton.batchModeOff
            case .multi:
                return CaptureModeButton.batchModeOn
            }
        }()
        setImage(image, animated: animated)
        self.captureMode = captureMode
    }
}

private class MediaPickerThumbnailButton: UIButton {

    required init() {
        let buttonSize = MediaPickerThumbnailButton.visibleSize + 2*MediaPickerThumbnailButton.contentMargin
        super.init(frame: CGRect(origin: .zero, size: .square(buttonSize)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static let visibleSize: CGFloat = 42
    private static let contentMargin: CGFloat = 8

    func configure() {
        contentEdgeInsets = UIEdgeInsets(margin: MediaPickerThumbnailButton.contentMargin)

        let placeholderView = UIVisualEffectView(effect: UIBlurEffect(style: .light))
        placeholderView.layer.cornerRadius = 10
        placeholderView.layer.borderWidth = 1.5
        placeholderView.layer.borderColor = UIColor.ows_whiteAlpha80.cgColor
        placeholderView.clipsToBounds = true
        placeholderView.isUserInteractionEnabled = false
        insertSubview(placeholderView, at: 0)
        placeholderView.autoPinEdgesToSuperviewEdges(withInsets: contentEdgeInsets)

        var authorizationStatus: PHAuthorizationStatus
        if #available(iOS 14, *) {
            authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } else {
            authorizationStatus = PHPhotoLibrary.authorizationStatus()
        }
        guard authorizationStatus == .authorized else { return }

        // Async Fetch last image
        DispatchQueue.global(qos: .userInteractive).async {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.fetchLimit = 1

            let fetchResult = PHAsset.fetchAssets(with: PHAssetMediaType.image, options: fetchOptions)
            if fetchResult.count > 0, let asset = fetchResult.firstObject {
                let targetImageSize = CGSize(square: MediaPickerThumbnailButton.visibleSize)
                PHImageManager.default().requestImage(for: asset, targetSize: targetImageSize, contentMode: .aspectFill, options: nil) { (image, _) in
                    if let image = image {
                        DispatchQueue.main.async {
                            self.updateWith(image: image)
                            placeholderView.alpha = 0
                        }
                    }
                }
            }
        }
    }

    private func updateWith(image: UIImage) {
        setImage(image, animated: self.window != nil)
        if let imageView = imageView {
            imageView.layer.cornerRadius = 10
            imageView.layer.borderWidth = 1.5
            imageView.layer.borderColor = UIColor.ows_whiteAlpha80.cgColor
            imageView.clipsToBounds = true
        }
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: contentEdgeInsets.leading + Self.visibleSize + contentEdgeInsets.trailing,
                      height: contentEdgeInsets.top + Self.visibleSize + contentEdgeInsets.bottom)
    }
}

class CapturePreviewView: UIView {

    let previewLayer: AVCaptureVideoPreviewLayer

    override var bounds: CGRect {
        didSet {
            previewLayer.frame = bounds
        }
    }

    override var frame: CGRect {
        didSet {
            previewLayer.frame = bounds
        }
    }

    override var contentMode: UIView.ContentMode {
        get {
            switch previewLayer.videoGravity {
            case .resizeAspectFill:
                return .scaleAspectFill
            case .resizeAspect:
                return .scaleAspectFit
            case .resize:
                return .scaleToFill
            default:
                owsFailDebug("Unexpected contentMode")
                return .scaleToFill
            }
        }
        set {
            switch newValue {
            case .scaleAspectFill:
                previewLayer.videoGravity = .resizeAspectFill
            case .scaleAspectFit:
                previewLayer.videoGravity = .resizeAspect
            case .scaleToFill:
                previewLayer.videoGravity = .resize
            default:
                owsFailDebug("Unexpected contentMode")
            }
        }
    }

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        if Platform.isSimulator {
            // helpful for debugging layout on simulator which has no real capture device
            previewLayer.backgroundColor = UIColor.green.withAlphaComponent(0.4).cgColor
        }
        super.init(frame: .zero)
        self.contentMode = .scaleAspectFill
        previewLayer.frame = bounds
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable, message: "Use init(session:) instead")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private class RecordingTimerView: PillView {

    override init(frame: CGRect) {
        super.init(frame: frame)

        layoutMargins = UIEdgeInsets(hMargin: 16, vMargin: 9)

        let backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        addSubview(backgroundView)
        backgroundView.autoPinEdgesToSuperviewEdges()

        let stackView = UIStackView(arrangedSubviews: [icon, label])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 5
        addSubview(stackView)
        stackView.autoPinEdgesToSuperviewMargins()

        updateView()
    }

    @available(*, unavailable, message: "Use init(frame:) instead")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Subviews

    private let label: UILabel = {
        let label = UILabel()
        label.font = UIFont.ows_monospacedDigitFont(withSize: 20)
        label.textAlignment = .center
        label.textColor = UIColor.white
        return label
    }()

    private let icon: UIView = {
        let icon = CircleView()
        icon.backgroundColor = .red
        icon.autoSetDimensions(to: CGSize(square: 6))
        icon.alpha = 0
        return icon
    }()

    // MARK: -

    var recordingStartTime: TimeInterval?

    func startCounting() {
        guard timer == nil else { return }
        recordingStartTime = CACurrentMediaTime()
        timer = Timer.weakScheduledTimer(withTimeInterval: 0.1, target: self, selector: #selector(updateView), userInfo: nil, repeats: true)
        UIView.animate(withDuration: 0.5,
                       delay: 0,
                       options: [.autoreverse, .repeat],
                       animations: { self.icon.alpha = 1 })
        updateView()
    }

    func stopCounting() {
        timer?.invalidate()
        timer = nil
        icon.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.4) {
            self.icon.alpha = 0
        }
    }

    // MARK: -

    private var timer: Timer?

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")!

        return formatter
    }()

    // This method should only be called when the call state is "connected".
    var recordingDuration: TimeInterval {
        guard let recordingStartTime = recordingStartTime else {
            return 0
        }

        return CACurrentMediaTime() - recordingStartTime
    }

    @objc
    private func updateView() {
        let recordingDuration = self.recordingDuration
        let durationDate = Date(timeIntervalSinceReferenceDate: recordingDuration)
        label.text = timeFormatter.string(from: durationDate)
    }
}

private protocol CameraZoomSelectionControlDelegate: AnyObject {

    func cameraZoomControl(_ cameraZoomControl: CameraZoomSelectionControl, didSelect camera: PhotoCapture.CameraType)

    func cameraZoomControl(_ cameraZoomControl: CameraZoomSelectionControl, didChangeZoomFactor zoomFactor: CGFloat)
}

private class CameraZoomSelectionControl: PillView {

    weak var delegate: CameraZoomSelectionControlDelegate?

    private let availableCameras: [PhotoCapture.CameraType]

    var selectedCamera: PhotoCapture.CameraType
    var currentZoomFactor: CGFloat {
        didSet {
            var viewFound = false
            for selectionView in selectionViews.reversed() {
                if currentZoomFactor >= selectionView.defaultZoomFactor && !viewFound {
                    selectionView.isSelected = true
                    selectionView.currentZoomFactor = currentZoomFactor
                    selectionView.update(animated: true)
                    viewFound = true
                } else if selectionView.isSelected {
                    selectionView.isSelected = false
                    selectionView.update(animated: true)
                }
            }
        }
    }

    private let stackView: UIStackView = {
        let stackView = UIStackView()
        stackView.spacing = 2
        stackView.axis = UIDevice.current.isIPad ? .vertical : .horizontal
        stackView.preservesSuperviewLayoutMargins = true
        stackView.isLayoutMarginsRelativeArrangement = true
        return stackView
    }()
    private let selectionViews: [CameraSelectionCircleView]

    var cameraZoomLevelIndicators: [UIView] {
        selectionViews
    }

    var axis: NSLayoutConstraint.Axis {
        get {
            stackView.axis
        }
        set {
            stackView.axis = newValue
        }
    }

    required init(availableCameras: [(cameraType: PhotoCapture.CameraType, defaultZoomFactor: CGFloat)]) {
        owsAssertDebug(!availableCameras.isEmpty, "availableCameras must not be empty.")

        self.availableCameras = availableCameras.map { $0.cameraType }

        let (wideAngleCamera, wideAngleCameraZoomFactor) = availableCameras.first(where: { $0.cameraType == .wideAngle }) ?? availableCameras.first!
        selectedCamera = wideAngleCamera
        currentZoomFactor = wideAngleCameraZoomFactor

        selectionViews = availableCameras.map { CameraSelectionCircleView(camera: $0.cameraType, defaultZoomFactor: $0.defaultZoomFactor) }

        super.init(frame: .zero)

        backgroundColor = selectionViews.count > 1 ? .ows_blackAlpha20 : .clear
        layoutMargins = UIEdgeInsets(margin: 2)

        selectionViews.forEach { view in
            view.isSelected = view.camera == selectedCamera
            view.autoSetDimensions(to: .square(38))
            view.update(animated: false)
        }
        stackView.addArrangedSubviews(selectionViews)
        addSubview(stackView)
        stackView.autoPinEdgesToSuperviewEdges()

        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(gesture:)))
        addGestureRecognizer(tapGestureRecognizer)
    }

    @available(*, unavailable, message: "Use init(availableCameras:) instead")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Selection

    @objc
    public func handleTap(gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }

        var tappedView: CameraSelectionCircleView?
        for selectionView in selectionViews {
            if selectionView.point(inside: gesture.location(in: selectionView), with: nil) {
                tappedView = selectionView
                break
            }
        }

        if let selectedView = tappedView {
            selectionViews.forEach { view in
                if view.isSelected && view != selectedView {
                    view.isSelected = false
                    view.update(animated: true)
                } else if view == selectedView {
                    view.isSelected = true
                    view.update(animated: true)
                }
            }
            selectedCamera = selectedView.camera
            delegate?.cameraZoomControl(self, didSelect: selectedCamera)
        }
    }

    private class CameraSelectionCircleView: UIView {

        let camera: PhotoCapture.CameraType
        let defaultZoomFactor: CGFloat
        var currentZoomFactor: CGFloat = 1

        private let circleView: CircleView = {
            let circleView = CircleView()
            circleView.backgroundColor = .ows_blackAlpha60
            return circleView
        }()

        private let textLabel: UILabel = {
            let label = UILabel()
            label.textAlignment = .center
            label.textColor = .ows_white
            label.font = .ows_semiboldFont(withSize: 11)
            return label
        }()

        required init(camera: PhotoCapture.CameraType, defaultZoomFactor: CGFloat) {
            self.camera = camera
            self.defaultZoomFactor = defaultZoomFactor
            self.currentZoomFactor = defaultZoomFactor

            super.init(frame: .zero)

            addSubview(circleView)
            addSubview(textLabel)
            textLabel.autoPinEdgesToSuperviewEdges()
        }

        @available(*, unavailable, message: "Use init(camera:defaultZoomFactor:) instead")
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            circleView.bounds = CGRect(origin: .zero, size: CGSize(square: circleDiameter))
            circleView.center = bounds.center
        }

        var isSelected: Bool = false {
            didSet {
                if !isSelected {
                    currentZoomFactor = defaultZoomFactor
                }
            }
        }

        private var circleDiameter: CGFloat {
            let circleDiameter = isSelected ? bounds.width : bounds.width * 24 / 38
            return ceil(circleDiameter)
        }

        private static let numberFormatterNormal: NumberFormatter = {
            let numberFormatter = NumberFormatter()
            numberFormatter.numberStyle = .decimal
            numberFormatter.minimumIntegerDigits = 0
            numberFormatter.maximumFractionDigits = 1
            return numberFormatter
        }()

        private static let numberFormatterSelected: NumberFormatter = {
            let numberFormatter = NumberFormatter()
            numberFormatter.numberStyle = .decimal
            numberFormatter.minimumIntegerDigits = 1
            numberFormatter.maximumFractionDigits = 1
            return numberFormatter
        }()

        private class func cameraLabel(forZoomFactor zoomFactor: CGFloat, isSelected: Bool) -> String {
            let numberFormatter = isSelected ? numberFormatterSelected : numberFormatterNormal
            // Don't allow 0.95 to be rounded to 1.
            let adjustedZoomFactor = floor(zoomFactor * 10) / 10
            guard var scaleString = numberFormatter.string(for: adjustedZoomFactor) else {
                return ""
            }
            if isSelected {
                scaleString.append("×")
            }
            return scaleString
        }

        static private let animationDuration: TimeInterval = 0.2
        func update(animated: Bool) {
            textLabel.text = Self.cameraLabel(forZoomFactor: currentZoomFactor, isSelected: isSelected)

            let animations = {
                if self.isSelected {
                    self.textLabel.layer.transform = CATransform3DMakeScale(1.2, 1.2, 1)
                } else {
                    self.textLabel.layer.transform = CATransform3DIdentity
                }

                self.setNeedsLayout()
                self.layoutIfNeeded()
            }

            if animated {
                UIView.animate(withDuration: Self.animationDuration,
                               delay: 0,
                               options: [ .curveEaseInOut ]) {
                    animations()
                }
            } else {
                animations()
            }
        }

        override var isAccessibilityElement: Bool {
            get { false }
            set { super.isAccessibilityElement = newValue }
        }
    }
}

// MARK: - Accessibility

extension FlashModeButton {

    override var accessibilityLabel: String? {
        get {
            NSLocalizedString("CAMERA_VO_FLASH_BUTTON",
                              comment: "VoiceOver label for Flash button in camera.")
        }
        set { super.accessibilityLabel = newValue }
    }

    override var accessibilityValue: String? {
        get {
            switch flashMode {
            case .auto:
                return NSLocalizedString("CAMERA_VO_FLASH_AUTO",
                                         comment: "VoiceOver description of current flash setting.")

            case .on:
                return NSLocalizedString("CAMERA_VO_FLASH_ON",
                                         comment: "VoiceOver description of current flash setting.")

            case .off:
                return NSLocalizedString("CAMERA_VO_FLASH_OFF",
                                         comment: "VoiceOver description of current flash setting.")

            @unknown default:
                owsFailDebug("unexpected photoCapture.flashMode: \(flashMode.rawValue)")
                return nil
            }
        }
        set { super.accessibilityValue = newValue }
    }
}

extension CameraChooserButton {

    override var accessibilityLabel: String? {
        get {
            NSLocalizedString("CAMERA_VO_CAMERA_CHOOSER_BUTTON",
                              comment: "VoiceOver label for Switch Camera button in in-app camera.")
        }
        set { super.accessibilityLabel = newValue }
    }

    override var accessibilityHint: String? {
        get {
            NSLocalizedString("CAMERA_VO_CAMERA_CHOOSER_HINT",
                              comment: "VoiceOver hint for Switch Camera button in in-app camera.")
        }
        set { super.accessibilityHint = newValue }
    }

    override var accessibilityValue: String? {
        get {
            if isFrontCameraActive {
                return NSLocalizedString("CAMERA_VO_CAMERA_FRONT_FACING",
                                         comment: "VoiceOver value for Switch Camera button that tells which camera is currently active.")
            } else {
                return NSLocalizedString("CAMERA_VO_CAMERA_BACK_FACING",
                                         comment: "VoiceOver value for Switch Camera button that tells which camera is currently active.")
            }
        }
        set { super.accessibilityValue = newValue }
    }
}

extension CaptureModeButton {

    override var accessibilityLabel: String? {
        get {
            NSLocalizedString("CAMERA_VO_CAMERA_ALBUM_MODE",
                              comment: "VoiceOver label for Flash button in camera.")
        }
        set { super.accessibilityLabel = newValue }
    }

    override var accessibilityValue: String? {
        get {
            switch captureMode {
            case .single:
                return NSLocalizedString("CAMERA_VO_CAMERA_ALBUM_MODE_OFF",
                                         comment: "VoiceOver label for Switch Camera button in in-app camera.")

            case .multi:
                return NSLocalizedString("CAMERA_VO_CAMERA_ALBUM_MODE_ON",
                                         comment: "VoiceOver label for Switch Camera button in in-app camera.")
            }
        }
        set { super.accessibilityValue = newValue }
    }
}

extension MediaPickerThumbnailButton {

    override var accessibilityLabel: String? {
        get {
            NSLocalizedString("CAMERA_VO_PHOTO_LIBRARY_BUTTON",
                          comment: "VoiceOver label for button to choose existing photo/video in in-app camera")
        }
        set { super.accessibilityLabel = newValue }
    }
}

extension CameraZoomSelectionControl {

    override var isAccessibilityElement: Bool {
        get { true }
        set { super.isAccessibilityElement = newValue }
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { [ .button, .adjustable ] }
        set { super.accessibilityTraits = newValue }
    }

    override var accessibilityLabel: String? {
        get {
            NSLocalizedString("CAMERA_VO_ZOOM", comment: "VoiceOver label for camera zoom control.")
        }
        set { super.accessibilityLabel = newValue }
    }

    private static let voiceOverNumberFormatter: NumberFormatter = {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.minimumIntegerDigits = 1
        numberFormatter.minimumFractionDigits = 1
        numberFormatter.maximumFractionDigits = 1
        return numberFormatter
    }()

    override var accessibilityValue: String? {
        get {
            guard let zoomValueString = CameraZoomSelectionControl.voiceOverNumberFormatter.string(for: currentZoomFactor) else { return nil }

            let formatString = NSLocalizedString("CAMERA_VO_ZOOM_LEVEL",
                                                 comment: "VoiceOver description of current camera zoom level.")
            return String(format: formatString, zoomValueString)
        }
        set { super.accessibilityValue = newValue }
    }

    override func accessibilityActivate() -> Bool {
        // Tapping on a single available camera switches between 1x and 2x.
        guard availableCameras.count > 1 else {
            delegate?.cameraZoomControl(self, didSelect: selectedCamera)
            return true
        }

        // Cycle through cameras.
        guard let selectedCameraIndex = availableCameras.firstIndex(of: selectedCamera) else { return false }
        var nextCameraIndex = availableCameras.index(after: selectedCameraIndex)
        if nextCameraIndex >= availableCameras.endIndex {
            nextCameraIndex = availableCameras.startIndex
        }
        let nextCamera = availableCameras[nextCameraIndex]
        selectedCamera = nextCamera
        delegate?.cameraZoomControl(self, didSelect: nextCamera)
        return true
    }

    override func accessibilityIncrement() {
        // Increment zoom by 0.1.
        currentZoomFactor = 0.1 * round(currentZoomFactor * 10 + 1)
        delegate?.cameraZoomControl(self, didChangeZoomFactor: currentZoomFactor)
    }

    override func accessibilityDecrement() {
        // Decrement zoom by 0.1.
        currentZoomFactor = 0.1 * round(currentZoomFactor * 10 - 1)
        delegate?.cameraZoomControl(self, didChangeZoomFactor: currentZoomFactor)
    }
}

private extension UIView {

    func embeddedInContainerView(layoutMargins: UIEdgeInsets = .zero) -> UIView {
        var containerViewFrame = bounds
        containerViewFrame.width += layoutMargins.leading + layoutMargins.trailing
        containerViewFrame.height += layoutMargins.top + layoutMargins.bottom
        let containerView = UIView(frame: containerViewFrame)
        containerView.layoutMargins = layoutMargins
        containerView.addSubview(self)
        autoPinEdgesToSuperviewMargins()
        return containerView
    }
}
