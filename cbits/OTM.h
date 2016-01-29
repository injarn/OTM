#include <Rts.h>
#include <RtsAPI.h>
// Refcounting for stableptrs
typedef struct OtmStablePtr_
{
    HsStablePtr     ptr;
    HsInt           volatile count; // Ref counter
} *OtmStablePtr;
/* All the necessary to make a condition variable work */
typedef struct cond_t {
    Mutex     mutex;
    Condition cond;
    HsInt     value;
    HsInt     generation;
} Cond;

// STM Data structures

// typedef struct StgTRecHeader_ StgTRecHeader;

typedef struct OTRecHeader_  OTRecHeader;
typedef struct OTRecEntry_   OTRecEntry;

// typedef struct StgTVarWatchQueue_ {
//   StgHeader                  header;
//   StgClosure                *closure; // StgTSO or StgAtomicInvariant
//   struct StgTVarWatchQueue_ *next_queue_entry;
//   struct StgTVarWatchQueue_ *prev_queue_entry;
// } StgTVarWatchQueue;

typedef struct OTVarWatchQueue_ {
    Cond                       *cond;
    HsInt                       generation;
    struct OTVarWatchQueue_    *next_queue_entry;
    struct OTVarWatchQueue_    *prev_queue_entry;
} OTVarWatchQueue;

// typedef struct {
//   StgHeader                  header;
//   StgClosure                *volatile current_value;
//   StgTVarWatchQueue         *volatile first_watch_queue_entry;
//   StgInt                     volatile num_updates;
// } StgTVar;

// typedef void* HsStablePtr; // HsFFI.h

/*  Working memory associated with an OTVar
    more suitable for atomic operations */
typedef struct {
    OtmStablePtr     volatile new_value;
    HsWord           volatile num_updates;
    OTRecHeader             *trec;
} OTVarDelta;

typedef struct {
    OtmStablePtr        volatile current_value;
    OTVarWatchQueue    *volatile first_watch_queue_entry;
    HsWord              volatile num_updates;
    HsWord              volatile locked;
    OTVarDelta         *volatile delta;
    // OTRecHeader        *volatile trec;   // The transaction that made the last operation, probably not needed
    // OTRecEntry         *volatile entry;  // Working memory
} OTVar;


// typedef struct {
//   StgHeader      header;
//   StgClosure    *code;
//   StgTRecHeader *last_execution;
//   StgWord        lock;
// } StgAtomicInvariant;

// /* new_value == expected_value for read-only accesses */
// /* new_value is a StgTVarWatchQueue entry when trec in state TREC_WAITING */
// typedef struct {
//   StgTVar                   *tvar;
//   StgClosure                *expected_value;
//   StgClosure                *new_value;
// #if defined(THREADED_RTS)
//   StgInt                     num_updates;
// #endif
// } TRecEntry;

/* new_value == expected_value for read-only accesses 
   expected_value & new_value ignored by otm read and write
   */
struct OTRecEntry_ {
    OTVar          *otvar;
    OtmStablePtr    expected_value;
    OtmStablePtr    new_value;
    HsInt           num_updates;
};

#define OTREC_CHUNK_NUM_ENTRIES 16

// typedef struct StgTRecChunk_ {
//   StgHeader                  header;
//   struct StgTRecChunk_      *prev_chunk;
//   StgWord                    next_entry_idx;
//   TRecEntry                  entries[TREC_CHUNK_NUM_ENTRIES];
// } StgTRecChunk;

typedef struct OTRecChunk_ {
    struct OTRecChunk_          *prev_chunk;
    HsWord                       next_entry_idx;
    OTRecEntry                   entries[OTREC_CHUNK_NUM_ENTRIES];
} OTRecChunk;

/* Open Transaction State */
typedef enum StgWord {
  OTREC_LOCKED      = 1,      /* Transaction record locked */
  OTREC_RUNNING     = 1 << 1, /* Transaction in progress, outcome undecided */
  OTREC_COMMIT      = 1 << 2, /* Transaction in the state Co< n,l > */
  OTREC_RETRY       = 1 << 3, /* Transaction in the state Re< n,l > */
  OTREC_ABORT       = 1 << 4, /* Transaction in the state Ab< n,l,e > */
  OTREC_COMMITED    = 1 << 5, /* Transaction has committed C<>!, now updating tvars */
  OTREC_RETRYED     = 1 << 6, /* Transaction has retryed R<>!, now reverting tvars */
  OTREC_ABORTED     = 1 << 7, /* Transaction has aborted A<e>!, now reverting tvars */
  OTREC_WAITING     = 1 << 8, /* Transaction currently waiting */
  OTREC_CONDEMNED   = 1 << 9, /* Transaction in progress, inconsistent / out of date reads */
} OTState;

/*  The choice of encapsulate toghether the state of the atomic computation
    and the state of the Union-Find could allow to update the state of the
    computation with atomic CAS. In fact, keeping the state and the Union-Find
    not tied up toghether, could lead in a update of the wrong root if an Union
    occours while we are updating the state.
    Does not seems to be a good idea, because if I update my next field i don't
    need to update my threads and running fields.
*/
typedef struct {
    OTState          state;
    HsWord           threads;
    HsWord           running;
    HsStablePtr      exception;
    // OTRecHeader     *next;
    // HsWord           rank;
} OTRecState;

// typedef struct StgInvariantCheckQueue_ {
//   StgHeader                       header;
//   StgAtomicInvariant             *invariant;
//   StgTRecHeader                  *my_execution;
//   struct StgInvariantCheckQueue_ *next_queue_entry;
// } StgInvariantCheckQueue;

// struct StgTRecHeader_ {
//   StgHeader                  header;
//   struct StgTRecHeader_     *enclosing_trec;
//   StgTRecChunk              *current_chunk;
//   StgInvariantCheckQueue    *invariants_to_check;
//   TRecState                  state;
// };

typedef struct OTRecNode_ {
    OTRecHeader* next;
    HsWord rank;
} OTRecNode;

// typedef OTRecState OTRecNode;

struct OTRecHeader_ {
    HsStablePtr                  thread_id; // Needed for throwTo
    struct OTRecHeader_         *enclosing_trec;
    // parent of this trec in the Make-Union-Find
    // forward_trec == NULL -> Isolated Transaction
    OTRecNode                   *volatile forward_trec;
    OTRecChunk                  *current_chunk;
    //  Invariants that we haven't
    /*  State che è anche la flag per il locking in fase di fusione,
        e contiene i contatori di quante transazioni devo aspettare prima di commitare */
    OTRecState                   volatile state;
    Cond                         condition_variable;
    HsWord                       reference_counter; // Forse non mi convine buttarlo via
};


HsBool compareStablePtr(HsStablePtr s1, HsStablePtr s2);

/* Union-Find */
OTRecHeader* find(OTRecHeader* trec);

OTRecHeader* otmStartTransaction(HsStablePtr thread_id, OTRecHeader* outer);
HsStablePtr otmGetThreadId(OTRecHeader* otrec);
OTVar* otmNewOTVar(HsStablePtr value);
HsStablePtr otmReadOTVar(OTRecHeader* trec, OTVar* otvar);
void otmWriteOTVar(OTRecHeader *trec, OTVar *otvar, HsStablePtr new_value);
OTState otmCommit(OTRecHeader* trec);
OTState otmRetry(OTRecHeader* trec);
OTState otmAbort(OTRecHeader* trec, HsStablePtr some_exception);

HsStablePtr itmReadOTVar(OTRecHeader* trec, OTVar* otvar);
void itmWriteOTVar(OTRecHeader* trec, OTVar* otvar, HsStablePtr new_value);
HsBool itmCommitTransaction(OTRecHeader* trec);

