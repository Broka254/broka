// BROKA v5.0 - Dispute Engine Repository
// Covers both legacy /disputes/* and new /disputes/v2/* endpoints.

import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';

// ── Evidence types (mirrors backend EvidenceType enum) ──────────────────────
enum EvidenceType {
  photo,
  video,
  voiceNote,
  trackingScreenshot,
  invoice,
  courierProof,
  packagingPhoto,
  other;

  String get value => switch (this) {
    EvidenceType.photo             => 'photo',
    EvidenceType.video             => 'video',
    EvidenceType.voiceNote         => 'voice_note',
    EvidenceType.trackingScreenshot => 'tracking_screenshot',
    EvidenceType.invoice           => 'invoice',
    EvidenceType.courierProof      => 'courier_proof',
    EvidenceType.packagingPhoto    => 'packaging_photo',
    EvidenceType.other             => 'other',
  };
}

// ── Case branch (mirrors backend CaseBranch enum) ───────────────────────────
enum CaseBranch {
  A1, A2, A3, A4, B;
  String get value => name; // "A1", "A2", etc.
}

// ── Case state (mirrors backend CaseState enum) ─────────────────────────────
enum CaseState {
  open,
  waitingSellerExplanation,
  waitingBuyerDecision,
  waitingReplacement,
  waitingReturn,
  aiReview,
  readyForRefund,
  readyForRelease,
  escalated,
  closedRefunded,
  closedReleased;

  static CaseState fromString(String s) => switch (s) {
    'open'                       => CaseState.open,
    'waiting_seller_explanation' => CaseState.waitingSellerExplanation,
    'waiting_buyer_decision'     => CaseState.waitingBuyerDecision,
    'waiting_replacement'        => CaseState.waitingReplacement,
    'waiting_return'             => CaseState.waitingReturn,
    'ai_review'                  => CaseState.aiReview,
    'ready_for_refund'           => CaseState.readyForRefund,
    'ready_for_release'          => CaseState.readyForRelease,
    'escalated'                  => CaseState.escalated,
    'closed_refunded'            => CaseState.closedRefunded,
    'closed_released'            => CaseState.closedReleased,
    _                            => CaseState.open,
  };

  bool get isTerminal => this == CaseState.closedRefunded || this == CaseState.closedReleased;
  bool get isActive   => !isTerminal && this != CaseState.escalated;

  String get displayLabel => switch (this) {
    CaseState.open                       => 'Under Review',
    CaseState.waitingSellerExplanation   => 'Waiting for Seller',
    CaseState.waitingBuyerDecision       => 'Your Decision Needed',
    CaseState.waitingReplacement         => 'Awaiting Replacement',
    CaseState.waitingReturn              => 'Awaiting Return',
    CaseState.aiReview                   => 'Zeno Analysing',
    CaseState.readyForRefund             => 'Refund in Progress',
    CaseState.readyForRelease            => 'Release in Progress',
    CaseState.escalated                  => 'Escalated — Human Review',
    CaseState.closedRefunded             => 'Refunded ✓',
    CaseState.closedReleased             => 'Funds Released ✓',
  };
}

// ── Dispute Case model ───────────────────────────────────────────────────────
class DisputeCase {
  final String id;
  final String dealId;
  final String openerId;
  final CaseBranch? branch;
  final CaseState state;
  final String? aiRecommendation;
  final double? aiConfidence;
  final String? aiAnalysisText;
  final String? ruleDecision;
  final String? ruleDecisionReason;
  final String? fundAction;
  final double? fundAmount;
  final String? fundExecutedAt;
  final String? zacCode;
  final int replacementCycle;
  final String createdAt;
  final String? closedAt;
  final List<DisputeEvidence> evidence;

  const DisputeCase({
    required this.id,
    required this.dealId,
    required this.openerId,
    this.branch,
    required this.state,
    this.aiRecommendation,
    this.aiConfidence,
    this.aiAnalysisText,
    this.ruleDecision,
    this.ruleDecisionReason,
    this.fundAction,
    this.fundAmount,
    this.fundExecutedAt,
    this.zacCode,
    this.replacementCycle = 0,
    required this.createdAt,
    this.closedAt,
    this.evidence = const [],
  });

  factory DisputeCase.fromJson(Map<String, dynamic> j) {
    final branchStr = j['branch'] as String?;
    CaseBranch? branch;
    if (branchStr != null) {
      branch = CaseBranch.values.where((b) => b.value == branchStr).firstOrNull;
    }
    final evidenceList = (j['evidence'] as List<dynamic>? ?? [])
        .map((e) => DisputeEvidence.fromJson(e as Map<String, dynamic>))
        .toList();
    return DisputeCase(
      id:                  j['id'] as String,
      dealId:              j['deal_id'] as String,
      openerId:            j['opener_id'] as String,
      branch:              branch,
      state:               CaseState.fromString(j['state'] as String? ?? 'open'),
      aiRecommendation:    j['ai_recommendation'] as String?,
      aiConfidence:        (j['ai_confidence'] as num?)?.toDouble(),
      aiAnalysisText:      j['ai_analysis_text'] as String?,
      ruleDecision:        j['rule_decision'] as String?,
      ruleDecisionReason:  j['rule_decision_reason'] as String?,
      fundAction:          j['fund_action'] as String?,
      fundAmount:          (j['fund_amount'] as num?)?.toDouble(),
      fundExecutedAt:      j['fund_executed_at'] as String?,
      zacCode:             j['zac_code'] as String?,
      replacementCycle:    j['replacement_cycle'] as int? ?? 0,
      createdAt:           j['created_at'] as String,
      closedAt:            j['closed_at'] as String?,
      evidence:            evidenceList,
    );
  }
}

// ── Evidence model ───────────────────────────────────────────────────────────
class DisputeEvidence {
  final String id;
  final String type;
  final String uploaderRole;
  final String storageUrl;
  final String? aiAnalysis;
  final bool? aiFlagsDamage;
  final double? aiConfidence;
  final String? description;
  final String createdAt;

  const DisputeEvidence({
    required this.id,
    required this.type,
    required this.uploaderRole,
    required this.storageUrl,
    this.aiAnalysis,
    this.aiFlagsDamage,
    this.aiConfidence,
    this.description,
    required this.createdAt,
  });

  factory DisputeEvidence.fromJson(Map<String, dynamic> j) => DisputeEvidence(
    id:           j['id'] as String,
    type:         j['type'] as String,
    uploaderRole: j['uploader_role'] as String,
    storageUrl:   j['storage_url'] as String,
    aiAnalysis:   j['ai_analysis'] as String?,
    aiFlagsDamage: j['ai_flags_damage'] as bool?,
    aiConfidence: (j['ai_confidence'] as num?)?.toDouble(),
    description:  j['description'] as String?,
    createdAt:    j['created_at'] as String,
  );
}

// ── Timeline event model ─────────────────────────────────────────────────────
class DisputeTimelineEvent {
  final String id;
  final String eventType;
  final String actorId;
  final String? actorRole;
  final String? fromState;
  final String? toState;
  final String description;
  final Map<String, dynamic>? payload;
  final String createdAt;

  const DisputeTimelineEvent({
    required this.id,
    required this.eventType,
    required this.actorId,
    this.actorRole,
    this.fromState,
    this.toState,
    required this.description,
    this.payload,
    required this.createdAt,
  });

  factory DisputeTimelineEvent.fromJson(Map<String, dynamic> j) =>
      DisputeTimelineEvent(
        id:          j['id'] as String,
        eventType:   j['event_type'] as String,
        actorId:     j['actor_id'] as String,
        actorRole:   j['actor_role'] as String?,
        fromState:   j['from_state'] as String?,
        toState:     j['to_state'] as String?,
        description: j['description'] as String,
        payload:     j['payload'] as Map<String, dynamic>?,
        createdAt:   j['created_at'] as String,
      );
}

// ── Repository ────────────────────────────────────────────────────────────────
class DisputesRepository {
  final ApiClient _client;
  DisputesRepository({ApiClient? client}) : _client = client ?? apiClient;

  // ── v2 API ────────────────────────────────────────────────────────────────

  /// Open a new dispute case on a deal.
  Future<Result<DisputeCase>> openCase({
    required String dealId,
    required CaseBranch branch,
    required String description,
  }) async {
    try {
      final data = await _client.post('/disputes/v2/open', {
        'deal_id':     dealId,
        'branch':      branch.value,
        'description': description,
      });
      return Success(DisputeCase.fromJson(data as Map<String, dynamic>));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Get the active dispute case for a deal.
  Future<Result<DisputeCase?>> getCaseForDeal(String dealId) async {
    try {
      final data = await _client.get('/disputes/v2/deal/$dealId')
          as Map<String, dynamic>;
      final caseData = data['case'];
      if (caseData == null) return const Success(null);
      return Success(DisputeCase.fromJson(caseData as Map<String, dynamic>));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Get a dispute case by ID.
  Future<Result<DisputeCase>> getCase(String caseId) async {
    try {
      final data = await _client.get('/disputes/v2/$caseId');
      return Success(DisputeCase.fromJson(data as Map<String, dynamic>));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Attach evidence to a case. Pass [imageBase64] for photos to trigger AI analysis.
  Future<Result<Map<String, dynamic>>> attachEvidence({
    required String caseId,
    required EvidenceType evidenceType,
    String description = '',
    String imageBase64 = '',
    String storageUrl = '',
  }) async {
    try {
      final data = await _client.postForm('/disputes/v2/$caseId/evidence', {
        'evidence_type': evidenceType.value,
        'description':   description,
        'image_base64':  imageBase64,
        'storage_url':   storageUrl,
      });
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Run AI analysis + rule engine. Sets case state to ready_for_* or escalated.
  Future<Result<Map<String, dynamic>>> analyseCase(String caseId) async {
    try {
      final data = await _client.post('/disputes/v2/$caseId/analyse', {});
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Execute fund action (refund or release). Case must be in ready_for_* state.
  Future<Result<Map<String, dynamic>>> executeFundAction(String caseId) async {
    try {
      final data = await _client.post('/disputes/v2/$caseId/execute', {});
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Get the full immutable event timeline for a case.
  Future<Result<List<DisputeTimelineEvent>>> getTimeline(String caseId) async {
    try {
      final data = await _client.get('/disputes/v2/$caseId/timeline')
          as Map<String, dynamic>;
      final list = (data['timeline'] as List<dynamic>)
          .map((e) => DisputeTimelineEvent.fromJson(e as Map<String, dynamic>))
          .toList();
      return Success(list);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  // ── Legacy v1 API (kept for backward compat) ──────────────────────────────

  Future<Result<Map<String, dynamic>>> openDispute({
    required String dealId,
    required String issueType,
    required String description,
    String? zenoVerdict,
  }) async {
    try {
      final data = await _client.post('/disputes/open', {
        'deal_id':      dealId,
        'issue_type':   issueType,
        'description':  description,
        if (zenoVerdict != null) 'zeno_verdict': zenoVerdict,
      });
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Map<String, dynamic>>> getDispute(String disputeId) async {
    try {
      final data = await _client.get('/disputes/$disputeId');
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<List<Map<String, dynamic>>>> getMyDisputes() async {
    try {
      final data = await _client.get('/disputes/') as List;
      return Success(data.cast<Map<String, dynamic>>());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final disputesRepository = DisputesRepository();
