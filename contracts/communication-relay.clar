;; Communication Relay Contract
;; Manages data transmission between ground stations and satellites

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-INPUT (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-NOT-FOUND (err u103))
(define-constant ERR-INSUFFICIENT-BANDWIDTH (err u104))

;; Data Variables
(define-data-var next-relay-id uint u1)
(define-data-var total-bandwidth-used uint u0)
(define-data-var max-total-bandwidth uint u10000)

;; Data Maps
(define-map communication-relays
  uint
  {
    source: (string-ascii 64),
    destination: (string-ascii 64),
    bandwidth-allocated: uint,
    quality-score: uint,
    established-at: uint,
    owner: principal,
    active: bool
  }
)

(define-map ground-stations
  (string-ascii 64)
  {
    location: (string-ascii 128),
    max-bandwidth: uint,
    current-usage: uint,
    operator: principal,
    active: bool
  }
)

(define-map relay-paths
  (string-ascii 128)
  (list 10 uint)
)

(define-map bandwidth-usage
  principal
  uint
)

;; Private Functions
(define-private (calculate-path-quality (relay-ids (list 10 uint)))
  (fold calculate-relay-quality relay-ids u100)
)

(define-private (calculate-relay-quality (relay-id uint) (current-quality uint))
  (match (map-get? communication-relays relay-id)
    relay-data
    (let ((relay-quality (get quality-score relay-data)))
      (/ (* current-quality relay-quality) u100)
    )
    current-quality
  )
)

(define-private (update-bandwidth-usage (user principal) (bandwidth uint) (add bool))
  (let ((current-usage (default-to u0 (map-get? bandwidth-usage user))))
    (if add
      (map-set bandwidth-usage user (+ current-usage bandwidth))
      (map-set bandwidth-usage user (if (>= current-usage bandwidth) (- current-usage bandwidth) u0))
    )
  )
)

;; Public Functions
(define-public (register-ground-station (station-id (string-ascii 64)) (location (string-ascii 128)) (max-bandwidth uint))
  (begin
    (asserts! (> max-bandwidth u0) ERR-INVALID-INPUT)
    (asserts! (is-none (map-get? ground-stations station-id)) ERR-ALREADY-EXISTS)

    (map-set ground-stations station-id {
      location: location,
      max-bandwidth: max-bandwidth,
      current-usage: u0,
      operator: tx-sender,
      active: true
    })

    (ok true)
  )
)

(define-public (establish-relay (source (string-ascii 64)) (destination (string-ascii 64)) (bandwidth uint))
  (let ((relay-id (var-get next-relay-id))
        (current-total (var-get total-bandwidth-used)))
    (asserts! (> bandwidth u0) ERR-INVALID-INPUT)
    (asserts! (<= (+ current-total bandwidth) (var-get max-total-bandwidth)) ERR-INSUFFICIENT-BANDWIDTH)

    (map-set communication-relays relay-id {
      source: source,
      destination: destination,
      bandwidth-allocated: bandwidth,
      quality-score: u95,
      established-at: block-height,
      owner: tx-sender,
      active: true
    })

    (var-set total-bandwidth-used (+ current-total bandwidth))
    (var-set next-relay-id (+ relay-id u1))
    (update-bandwidth-usage tx-sender bandwidth true)

    (ok relay-id)
  )
)

(define-public (terminate-relay (relay-id uint))
  (match (map-get? communication-relays relay-id)
    relay-data
    (begin
      (asserts! (is-eq (get owner relay-data) tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (get active relay-data) ERR-NOT-FOUND)

      (map-set communication-relays relay-id (merge relay-data { active: false }))
      (var-set total-bandwidth-used (- (var-get total-bandwidth-used) (get bandwidth-allocated relay-data)))
      (update-bandwidth-usage tx-sender (get bandwidth-allocated relay-data) false)

      (ok true)
    )
    ERR-NOT-FOUND
  )
)

(define-public (update-quality-score (relay-id uint) (new-quality uint))
  (match (map-get? communication-relays relay-id)
    relay-data
    (begin
      (asserts! (is-eq (get owner relay-data) tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (<= new-quality u100) ERR-INVALID-INPUT)

      (map-set communication-relays relay-id (merge relay-data { quality-score: new-quality }))
      (ok true)
    )
    ERR-NOT-FOUND
  )
)

(define-public (create-relay-path (path-name (string-ascii 128)) (relay-ids (list 10 uint)))
  (begin
    (asserts! (> (len relay-ids) u0) ERR-INVALID-INPUT)
    (asserts! (is-none (map-get? relay-paths path-name)) ERR-ALREADY-EXISTS)

    (map-set relay-paths path-name relay-ids)
    (ok (calculate-path-quality relay-ids))
  )
)

(define-public (update-ground-station-usage (station-id (string-ascii 64)) (usage-change int))
  (match (map-get? ground-stations station-id)
    station-data
    (begin
      (asserts! (is-eq (get operator station-data) tx-sender) ERR-NOT-AUTHORIZED)

      (let ((current-usage (get current-usage station-data))
            (new-usage (if (>= usage-change 0)
                         (+ current-usage (to-uint usage-change))
                         (if (>= current-usage (to-uint (- 0 usage-change)))
                           (- current-usage (to-uint (- 0 usage-change)))
                           u0))))
        (asserts! (<= new-usage (get max-bandwidth station-data)) ERR-INSUFFICIENT-BANDWIDTH)

        (map-set ground-stations station-id (merge station-data { current-usage: new-usage }))
        (ok new-usage)
      )
    )
    ERR-NOT-FOUND
  )
)

;; Read-only Functions
(define-read-only (get-relay-details (relay-id uint))
  (map-get? communication-relays relay-id)
)

(define-read-only (get-ground-station (station-id (string-ascii 64)))
  (map-get? ground-stations station-id)
)

(define-read-only (get-relay-path (path-name (string-ascii 128)))
  (map-get? relay-paths path-name)
)

(define-read-only (get-path-quality (path-name (string-ascii 128)))
  (match (map-get? relay-paths path-name)
    relay-ids (some (calculate-path-quality relay-ids))
    none
  )
)

(define-read-only (get-bandwidth-usage (user principal))
  (map-get? bandwidth-usage user)
)

(define-read-only (get-total-bandwidth-stats)
  {
    used: (var-get total-bandwidth-used),
    max: (var-get max-total-bandwidth),
    available: (- (var-get max-total-bandwidth) (var-get total-bandwidth-used))
  }
)
