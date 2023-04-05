;; Copyright (c) 2021-2023 by Greg Hendershott.
;; SPDX-License-Identifier: GPL-3.0-or-later

#lang racket/base

(require racket/contract
         racket/match
         racket/set
         "analyze.rkt"
         "data-types.rkt"
         "span-map.rkt"
         (only-in "store.rkt"
                  [get-file store:get-file]
                  read-file-from-sqlite)
         (only-in "nominal-imports.rkt"
                  [lookup files-nominally-importing]))

(provide get-annotations
         get-completion-candidates
         get-errors
         get-point-info
         get-doc-link)

;;; Simple queries

;; Most annotations pertain to specific spans. There are various
;; kinds. get-annotations returns most mixed and sorted by position.
;; (See get-errors and get-completion-candidates for two things that
;; get-annotations does /not/ return.)
;;
;; 1. This query supports the sort of access pattern that Racket Mode's
;; "classic" racket-xp-mode uses: Get values for everything and put as
;; text properties into the buffer.
;;
;; That access pattern is not great for large files with a lot of
;; annotation data. It takes space on the front end client (e.g.
;; emacs/vim/vscode). Just as bad is marshaling overhead (converting
;; to/from json or sexp or whatever format is used for the Racket back
;; end to talk to the non-Racket front end).
;;
;; 2. This query also supports getting only a subset for a certain
;; span. This supports better access patterns. See also
;; `get-point-info`, below, which is especially optimized for one such
;; access pattern.
;;
;; TODO: Now that we record zero-span items, notably for things like
;; #%app and #%datum, we should add a flag here to ignore these. Some
;; clients -- certainly Emacs -- can't use these, and they are
;; numerous, so in such cases best not to marshal them at all.
(define/contract (get-annotations path [beg min-position] [end max-position])
  (->* (complete-path?) (position? position?) any) ;returns pdb?
  (define f (get-file path))
  (define (def-sites)
    (for/list ([v (in-list (span-map-refs (arrow-map-def->uses (file-arrows f)) beg end))])
      (match-define (cons (cons def-beg def-end) uses) v)
      (define import? (for/or ([use (in-set uses)]) (import-arrow? use)))
      (list 'def-site
            def-beg
            def-end
            import?
            (sort (for/list ([use (in-set uses)])
                    (list (arrow-use-beg use)
                          (arrow-use-end use)))
                  < #:key car))))
  (define (use-sites)
    (for/list ([v (in-list (span-map-refs (arrow-map-use->def (file-arrows f)) beg end))])
      (match-define (cons (cons use-beg use-end) a) v)
      (list 'use-site
            use-beg
            use-end
            (import-arrow? a)
            (arrow-def-beg a)
            (arrow-def-end a))))
  (define (mouse-overs)
    (for/list ([v (in-list (span-map-refs (file-mouse-overs f) beg end))])
      (match-define (cons (cons beg end) texts) v)
      (list 'mouse-over beg end texts)))
  (define (doc-sites)
    (for/list ([v (in-list (span-map-refs (file-docs f) beg end))])
      (match-define (cons (cons beg end) d) v)
      (list 'doc-link beg end (doc-path d) (doc-anchor d))))
  (define (unused-requires)
    (for/list ([v (in-list (span-map-refs (file-unused-requires f) beg end))])
      (match-define (cons (cons beg end) _) v)
      (list 'unused-require beg end)))
  (sort (append (def-sites)
                (use-sites)
                (mouse-overs)
                (doc-sites)
                (unused-requires))
        < #:key cadr))

;; Optionally accepts a position with the view that someday we'd build
;; a more-targeted data structure for this -- limited to /valid/
;; candidates within a module or even lexical scope. But for now we
;; continue the Racket Mode tradition of erring on the side of
;; offering more candidates, even if some aren't valid.
(define (get-completion-candidates path [_pos min-position])
  (define f (get-file path))
  (set-union
   (for/set ([v (in-set (file-imports f))]) ;-> immutable-set
     v)
   ;; ~= to getting candidates from syncheck:add-definition-target.
   (for/set ([v (in-hash-keys (file-defs f))])
     (ibk-sym v))
   ;; ~= to getting candidates from synchek:add-mouse-over messages
   ;; about "bound occurrence(s)", which includes lexical arrows, plus
   ;; more from our rename-arrows.
   (for*/fold ([s (set)])
              ([uses (in-list (span-map-values (arrow-map-def->uses (file-arrows f))))]
               [use (in-set uses)])
     (match use
       [(? lexical-arrow? a)
        (set-add s (lexical-arrow-sym a))]
       [(? rename-arrow? a)
        (set-add (set-add s (rename-arrow-old-sym a))
                 (rename-arrow-new-sym a))]
       [_ s]))))

;; Accepts no span or position on the theory that, when a file has one
;; or more errors, the user will always want to know and be able to go
;; to all of them, regardless of where they might be in the file.
(define (get-errors path)
  (for/list ([v (in-list (span-map->list (file-errors (get-file path))))])
    (match-define (list (cons beg end) (cons maybe-path message)) v)
    (list beg end
          (or maybe-path (path->string path))
          message)))

;; This is designed for a client that does not want to store any
;; persistent values on its end. For example, an Emacs mode that does
;; not store every annotation as a text property. Instead, upon
;; movement of window-point or window-{start end} (to use Emacs
;; terminology), it can call this to get only values pertaining to
;; that subset of the buffer. Presumably it can temporarily enhance
;; the presentation (e.g. add overlays in Emacs).
;;
;; In principle a client could write this itself by filtering
;; information from `get-annotations` Maybe this shouldn't even exist
;; as part of library, but just be example code? Anyway it's here for
;; now as I dog-food the use of pdb by Racket Mode for Emacs, and
;; learn more from some use in the real world.
(define (get-point-info path pos beg end)
  (define f (get-file path))
  (define (error-messages-here)
    (define-values (beg end a-set) (span-map-ref/bounds (file-errors f) pos #f))
    (and beg end a-set
         (not (set-empty? a-set))
         (list beg end
               (for*/set ([v (in-set a-set)]
                          [err-path (in-value (car v))]
                          [err-msg  (in-value (cdr v))]
                          #:when (or (not err-path)
                                     (equal? err-path (path->string path))))
                 err-msg))))
  ;; TODO: Should we return all mouse-overs for [beg end), in case the
  ;; client wants to support actual GUI tooltips? In that case if the
  ;; client wants to treat a mouse-over at point specially (e.g.
  ;; racket-show in Racket Mode), let it distinguish that itself?
  (define mouse-over
    (or (error-messages-here)
        (call-with-values (λ () (span-map-ref/bounds (file-mouse-overs f) pos #f))
                          (λ (beg end v) (and beg end v (list beg end v))))))
  ;; TODO: Filter use-sites that aren't within [beg end)? In the case
  ;; where there are very many use sites (hundreds or thousands?), it
  ;; could start to matter that we return so many that aren't visible.
  (define-values (def-site use-sites)
    (match (span-map-ref (arrow-map-use->def (file-arrows f)) pos #f)
      [(? arrow? u->d)
       #:when (not (import-arrow? u->d))
       (values (cons (arrow-def-beg u->d)
                     (arrow-def-end u->d))
               (for/list ([d->u (in-set (span-map-ref (arrow-map-def->uses (file-arrows f))
                                                      (arrow-def-beg u->d)
                                                      (set)))])
                 (cons (arrow-use-beg d->u)
                       (arrow-use-end d->u))))]
      [_
       (match (span-map-ref (arrow-map-def->uses (file-arrows f)) pos (set))
         [(? set? d->us)
          #:when (not (set-empty? d->us))
          (values (cons (arrow-def-beg (set-first d->us))
                        (arrow-def-end (set-first d->us)))
                  (for/list ([d->u (in-set d->us)]
                             #:when (not (import-arrow? d->u)))
                    (cons (arrow-use-beg d->u)
                          (arrow-use-end d->u))))]
         [_ (values #f #f)])]))
  (define unused-requires
    (map car (span-map-refs (file-unused-requires f) beg end)))
  (define unused-bindings
    (for/list ([v (in-list (span-map-refs (file-mouse-overs f) beg end))]
               #:when (set-member? (cdr v) "no bound occurrences"))
      (car v)))
  (hash
   ;; This pertains only to point
   'mouse-over      mouse-over
   ;; These pertain to point and related sites
   'def-site        def-site
   'use-sites       use-sites
   ;; These pertain to entire beg..end span
   'unused-requires unused-requires
   'unused-bindings unused-bindings))

(define (get-doc-link path pos)
  (span-map-ref (file-docs (get-file path)) pos #f))

(module+ ex
  (require racket/path)
  (get-annotations (simple-form-path "example/define.rkt") 1500 1530)
  (get-annotations (simple-form-path "example/typed-error.rkt"))
  (get-errors (simple-form-path "example/typed-error.rkt"))
  (get-errors (simple-form-path "example/require-error.rkt"))
  #;(get-completion-candidates (simple-form-path (build-path "example" "define.rkt")))
  (get-point-info (simple-form-path "example/define.rkt") 1353 1170 1536))

(module+ test
  (require racket/runtime-path
           rackunit
           (only-in "relations.rkt" use->def))
  (define-runtime-path require.rkt "example/require.rkt")
  (check-true
   (match (for/or ([a (in-list (get-annotations require.rkt 20 21))])
            (and (eq? 'use-site (car a))
                 a))
     [(list 'use-site 20 27 #t 7 18)
      (match (use->def require.rkt 20)
        [(list (? path?) 10485 10492) #t]
        [_ #f])]
     [_ #f])
   "We get a use-site with import? true, for `require`, and, use->def for that site gives the expected location in reqprov.rkt"))