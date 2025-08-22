;; Aegis Protocol - Decentralized Risk Mitigation and Collective Coverage Platform
;; A sophisticated peer-to-peer insurance ecosystem with autonomous governance

;; Define constants
(define-constant protocol-founder tx-sender)
(define-constant err-founder-only (err u100))
(define-constant err-already-deployed (err u101))
(define-constant err-not-deployed (err u102))
(define-constant err-vault-not-found (err u103))
(define-constant err-insufficient-capital (err u104))
(define-constant err-not-participant (err u105))
(define-constant err-settlement-not-found (err u106))
(define-constant err-invalid-vault-name (err u107))
(define-constant err-invalid-contribution (err u108))
(define-constant err-invalid-protection-limit (err u109))
(define-constant err-invalid-vault-id (err u110))
(define-constant err-invalid-settlement-amount (err u111))
(define-constant err-not-curator (err u112))
(define-constant err-invalid-curator (err u113))
(define-constant err-activity-not-found (err u114))
(define-constant err-settlement-window-expired (err u115))
(define-constant err-invalid-settlement-window (err u116))

;; Define data variables
(define-data-var protocol-deployed bool false)
(define-data-var vault-registry-count uint u0)
(define-data-var activity-log-counter uint u0)

;; Define data maps
(define-map risk-vaults
  { vault-id: uint }
  {
    vault-name: (string-ascii 50),
    capital-reserve: uint,
    entry-contribution: uint,
    protection-ceiling: uint,
    participants: (list 200 principal),
    vault-curator: principal,
    settlement-window: uint,  ;; Settlement window in seconds
    inception-timestamp: uint ;; Block time when vault was created
  }
)

(define-map settlement-requests
  { settlement-id: uint }
  {
    vault-id: uint,
    beneficiary: principal,
    requested-amount: uint,
    resolution-status: (string-ascii 20),
    submission-timestamp: uint  ;; Block time when settlement was submitted
  }
)

(define-map activity-ledger
  { activity-id: uint }
  {
    action-type: (string-ascii 20),
    vault-id: (optional uint),
    settlement-id: (optional uint),
    participant: (optional principal),
    transaction-value: (optional uint)
  }
)

;; Helper function to record activities
(define-private (record-activity (action-type (string-ascii 20)) 
                                 (vault-id (optional uint)) 
                                 (settlement-id (optional uint))
                                 (participant (optional principal))
                                 (transaction-value (optional uint)))
  (let ((activity-id (+ (var-get activity-log-counter) u1)))
    (var-set activity-log-counter activity-id)
    (map-set activity-ledger
      { activity-id: activity-id }
      {
        action-type: action-type,
        vault-id: vault-id,
        settlement-id: settlement-id,
        participant: participant,
        transaction-value: transaction-value
      }
    )
    activity-id
  )
)

;; Deploy protocol
(define-public (deploy-protocol)
  (begin
    (asserts! (is-eq tx-sender protocol-founder) err-founder-only)
    (asserts! (not (var-get protocol-deployed)) err-already-deployed)
    (var-set protocol-deployed true)
    (record-activity "deploy-protocol" none none none none)
    (ok true)
  )
)

;; Establish a new risk vault
(define-public (establish-vault (vault-name (string-ascii 50)) (entry-contribution uint) (protection-ceiling uint) (vault-curator principal) (settlement-window uint))
  (begin
    (asserts! (var-get protocol-deployed) err-not-deployed)
    (asserts! (> (len vault-name) u0) err-invalid-vault-name)
    (asserts! (> entry-contribution u0) err-invalid-contribution)
    (asserts! (> protection-ceiling entry-contribution) err-invalid-protection-limit)
    (asserts! (not (is-eq vault-curator tx-sender)) err-invalid-curator)
    (asserts! (> settlement-window u0) err-invalid-settlement-window)

    (let (
      (new-vault-id (+ (var-get vault-registry-count) u1))
      (current-timestamp (unwrap-panic (get-block-info? time u0)))
    )
      (map-set risk-vaults
        { vault-id: new-vault-id }
        {
          vault-name: vault-name,
          capital-reserve: u0,
          entry-contribution: entry-contribution,
          protection-ceiling: protection-ceiling,
          participants: (list),
          vault-curator: vault-curator,
          settlement-window: settlement-window,
          inception-timestamp: current-timestamp
        }
      )
      (var-set vault-registry-count new-vault-id)
      (record-activity "establish-vault" (some new-vault-id) none (some vault-curator) none)
      (ok new-vault-id)
    )
  )
)

;; Request participation in a risk vault
(define-public (request-vault-participation (vault-id uint))
  (begin
    (asserts! (var-get protocol-deployed) err-not-deployed)
    (asserts! (> vault-id u0) err-invalid-vault-id)
    (asserts! (<= vault-id (var-get vault-registry-count)) err-vault-not-found)
    
    (let (
      (vault (unwrap! (map-get? risk-vaults { vault-id: vault-id }) err-vault-not-found))
      (entry-contribution (get entry-contribution vault))
    )
      (asserts! (is-eq (stx-transfer? entry-contribution tx-sender (as-contract tx-sender)) (ok true)) err-insufficient-capital)
      (record-activity "request-join" (some vault-id) none (some tx-sender) none)
      (ok true)
    )
  )
)

;; Approve participation request (curator only)
(define-public (approve-participation (vault-id uint) (new-participant principal))
  (begin
    (asserts! (var-get protocol-deployed) err-not-deployed)
    (asserts! (> vault-id u0) err-invalid-vault-id)
    (asserts! (<= vault-id (var-get vault-registry-count)) err-vault-not-found)

    (let (
      (vault (unwrap! (map-get? risk-vaults { vault-id: vault-id }) err-vault-not-found))
    )
      (asserts! (is-eq tx-sender (get vault-curator vault)) err-not-curator)
      (asserts! (not (is-eq new-participant tx-sender)) err-invalid-curator)

      (map-set risk-vaults
        { vault-id: vault-id }
        (merge vault {
          capital-reserve: (+ (get capital-reserve vault) (get entry-contribution vault)),
          participants: (unwrap! (as-max-len? (append (get participants vault) new-participant) u200) err-vault-not-found)
        })
      )
      (record-activity "approve-join" (some vault-id) none (some new-participant) none)
      (ok true)
    )
  )
)

;; Submit settlement request
(define-public (submit-settlement (vault-id uint) (requested-amount uint))
  (begin
    (asserts! (var-get protocol-deployed) err-not-deployed)
    (asserts! (> vault-id u0) err-invalid-vault-id)
    (asserts! (<= vault-id (var-get vault-registry-count)) err-vault-not-found)
    (asserts! (> requested-amount u0) err-invalid-settlement-amount)
    
    (let (
      (vault (unwrap! (map-get? risk-vaults { vault-id: vault-id }) err-vault-not-found))
      (settlement-id (+ (var-get vault-registry-count) u1))
      (current-timestamp (unwrap-panic (get-block-info? time u0)))
    )
      (asserts! (is-some (index-of (get participants vault) tx-sender)) err-not-participant)
      (asserts! (<= requested-amount (get protection-ceiling vault)) err-insufficient-capital)
      (asserts! (<= current-timestamp (+ (get inception-timestamp vault) (get settlement-window vault))) err-settlement-window-expired)
      (map-set settlement-requests
        { settlement-id: settlement-id }
        {
          vault-id: vault-id,
          beneficiary: tx-sender,
          requested-amount: requested-amount,
          resolution-status: "under-review",
          submission-timestamp: current-timestamp
        }
      )
      (var-set vault-registry-count settlement-id)
      (record-activity "submit-settlement" (some vault-id) (some settlement-id) (some tx-sender) (some requested-amount))
      (ok settlement-id)
    )
  )
)

;; Process settlement request (curator only)
(define-public (process-settlement (settlement-id uint) (approve-settlement bool))
  (begin
    (asserts! (var-get protocol-deployed) err-not-deployed)
    (asserts! (> settlement-id u0) err-invalid-vault-id)
    (asserts! (<= settlement-id (var-get vault-registry-count)) err-settlement-not-found)
    
    (let (
      (settlement (unwrap! (map-get? settlement-requests { settlement-id: settlement-id }) err-settlement-not-found))
      (vault (unwrap! (map-get? risk-vaults { vault-id: (get vault-id settlement) }) err-vault-not-found))
      (current-timestamp (unwrap-panic (get-block-info? time u0)))
    )
      (asserts! (is-eq tx-sender (get vault-curator vault)) err-not-curator)
      (asserts! (<= current-timestamp (+ (get submission-timestamp settlement) (get settlement-window vault))) err-settlement-window-expired)
      (if approve-settlement
        (begin
          (asserts! (>= (get capital-reserve vault) (get requested-amount settlement)) err-insufficient-capital)
          (map-set risk-vaults
            { vault-id: (get vault-id settlement) }
            (merge vault { capital-reserve: (- (get capital-reserve vault) (get requested-amount settlement)) })
          )
          (unwrap! (as-contract (stx-transfer? (get requested-amount settlement) tx-sender (get beneficiary settlement))) err-insufficient-capital)
          (map-set settlement-requests { settlement-id: settlement-id } (merge settlement { resolution-status: "settled" }))
          (record-activity "process-settlement" (some (get vault-id settlement)) (some settlement-id) (some (get beneficiary settlement)) (some (get requested-amount settlement)))
        )
        (begin
          (map-set settlement-requests { settlement-id: settlement-id } (merge settlement { resolution-status: "declined" }))
          (record-activity "process-settlement" (some (get vault-id settlement)) (some settlement-id) (some (get beneficiary settlement)) none)
        )
      )
      (ok true)
    )
  )
)

;; Transfer vault curation rights
(define-public (transfer-curation (vault-id uint) (new-curator principal))
  (begin
    (asserts! (var-get protocol-deployed) err-not-deployed)
    (asserts! (> vault-id u0) err-invalid-vault-id)
    (asserts! (<= vault-id (var-get vault-registry-count)) err-vault-not-found)
    (asserts! (not (is-eq new-curator tx-sender)) err-invalid-curator)

    (let (
      (vault (unwrap! (map-get? risk-vaults { vault-id: vault-id }) err-vault-not-found))
    )
      (asserts! (is-eq tx-sender (get vault-curator vault)) err-not-curator)
      (map-set risk-vaults
        { vault-id: vault-id }
        (merge vault { vault-curator: new-curator })
      )
      (record-activity "transfer-curation" (some vault-id) none (some new-curator) none)
      (ok true)
    )
  )
)

;; Get vault information
(define-read-only (get-vault-details (vault-id uint))
  (begin
    (asserts! (> vault-id u0) err-invalid-vault-id)
    (asserts! (<= vault-id (var-get vault-registry-count)) err-vault-not-found)
    (ok (unwrap! (map-get? risk-vaults { vault-id: vault-id }) err-vault-not-found))
  )
)

;; Get settlement information
(define-read-only (get-settlement-details (settlement-id uint))
  (begin
    (asserts! (> settlement-id u0) err-invalid-vault-id)
    (asserts! (<= settlement-id (var-get vault-registry-count)) err-settlement-not-found)
    (ok (unwrap! (map-get? settlement-requests { settlement-id: settlement-id }) err-settlement-not-found))
  )
)

;; Get activity information
(define-read-only (get-activity-details (activity-id uint))
  (begin
    (asserts! (> activity-id u0) err-invalid-vault-id)
    (asserts! (<= activity-id (var-get activity-log-counter)) err-activity-not-found)
    (ok (unwrap! (map-get? activity-ledger { activity-id: activity-id }) err-activity-not-found))
  )
)

;; Get total activity count
(define-read-only (get-total-activities)
  (ok (var-get activity-log-counter))
)