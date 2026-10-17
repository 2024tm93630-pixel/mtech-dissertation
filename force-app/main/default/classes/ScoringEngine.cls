/**
 * ScoringEngine — pure, LLM-free derivation logic for the AI-assisted Backlog Decision Framework.
 *
 * Implements Project Blueprint v1.1 Section 7.1-7.4 (Decisions #22, #26, #27, #28, #29, #30).
 * The LLM returns only raw scores / checklist booleans / evidence. EVERYTHING else is computed here:
 *   Gate 1 state, Gate 2 Split/Merge signal + state + overlap flag, Gate 3 checklist scores + state,
 *   per-gate confidence, Overall_Confidence, and the Gate 4 recommendation + triggering rule.
 *
 * No SOQL, no DML, no callouts: fully unit-testable and deterministic.
 *
 * Exact-threshold design note: Overall_Confidence = (C1 + C2 + C3) / 3 with C1 = sum1/25, C2 = sum2/15,
 * C3 = sum3/15, which simplifies to (3*sum1 + 5*sum2 + 5*sum3) / 225. Threshold comparisons (0.75, 0.5)
 * are done on that integer numerator, so there is no floating-point/rounding ambiguity at the boundaries.
 */
public with sharing class ScoringEngine {

    public class ScoringException extends Exception {}

    // ---------- Output state / recommendation vocabulary (single source of truth) ----------
    public static final String G1_PASS            = 'Pass';
    public static final String G1_NEEDS_REWRITE   = 'Needs Rewrite';

    public static final String G2_CLEAN           = 'Clean';
    public static final String G2_DUP_FLAGGED     = 'Duplicate-flagged';
    public static final String G2_NEEDS_SPLIT     = 'Needs Split';
    public static final String G2_NEEDS_MERGE     = 'Needs Merge';

    public static final String G3_SPRINT_READY    = 'Sprint-Ready';
    public static final String G3_BLOCKED         = 'Blocked';
    public static final String G3_BACKLOG_HOLD    = 'Backlog-Hold';
    public static final String G3_ARCH_REVIEW     = 'Needs-Architecture-Review';

    public static final String SUBREASON_PENDING_G2 = 'Pending Gate 2 resolution';
    public static final String SUBREASON_READINESS  = 'Sprint readiness gap';

    public static final String REC_ENTER_SPRINT   = 'Enter Sprint';
    public static final String REC_REFINE_FIRST   = 'Refine First';
    public static final String REC_HOLD           = 'Hold';
    public static final String REC_DISCARD        = 'Discard/Reassess';

    public static final String DRIVER_NONE        = 'None';
    public static final String DRIVER_COMPLIANCE  = 'Compliance/Regulatory';
    public static final String DRIVER_RISK        = 'Risk Mitigation';

    private static final Set<String> VALID_DRIVERS = new Set<String>{
        'Revenue', 'Compliance/Regulatory', 'Operational Efficiency',
        'Customer Experience', 'Risk Mitigation', 'None'
    };
    private static final Set<String> VALID_G1_STATES = new Set<String>{ G1_PASS, G1_NEEDS_REWRITE };
    private static final Set<String> VALID_G2_STATES = new Set<String>{
        G2_CLEAN, G2_DUP_FLAGGED, G2_NEEDS_SPLIT, G2_NEEDS_MERGE
    };
    private static final Set<String> VALID_G3_STATES = new Set<String>{
        G3_SPRINT_READY, G3_BLOCKED, G3_BACKLOG_HOLD, G3_ARCH_REVIEW
    };

    // =====================================================================================
    // Input value objects (populated by the gate JSON parsers)
    // =====================================================================================

    public class Gate1Scores {
        public Integer completeness;
        public Integer clarity;
        public Integer acceptanceCriteria;
        public Integer invest;
        public Integer technicalApproach;
        public Gate1Scores() {}
        public Gate1Scores(Integer completeness, Integer clarity, Integer acceptanceCriteria,
                           Integer invest, Integer technicalApproach) {
            this.completeness = completeness;
            this.clarity = clarity;
            this.acceptanceCriteria = acceptanceCriteria;
            this.invest = invest;
            this.technicalApproach = technicalApproach;
        }
    }

    public class Gate2Scores {
        public Integer duplicateRisk;
        public Integer ambiguity;
        public Integer metadataOverlapRisk;
        public Gate2Scores() {}
        public Gate2Scores(Integer duplicateRisk, Integer ambiguity, Integer metadataOverlapRisk) {
            this.duplicateRisk = duplicateRisk;
            this.ambiguity = ambiguity;
            this.metadataOverlapRisk = metadataOverlapRisk;
        }
    }

    /** Gate 3: two 0-5 scores plus the two LLM-returned checklists (booleans only; Apex scores them). */
    public class Gate3Inputs {
        public Integer dependency;          // risk-style
        public Integer sprintReadiness;     // quality-style
        // Business Value checklist
        public String  driverCategory;
        public Boolean coreScope;
        public Boolean urgencySignal;
        public Boolean quantifiableImpact;
        // Deployment/Technical Risk checklist
        public Boolean bulkVolume;
        public Boolean calloutIntegration;
        public Boolean recursiveAutomation;
        public Boolean environmentReadiness;
    }

    // =====================================================================================
    // Result value objects
    // =====================================================================================

    public class Gate1Result {
        public String  state;
        public Integer rawSum;       // sum of the five scores (0-25)
        public Integer lowestScore;
    }

    public class Gate2Result {
        public Integer splitMergeSignal;
        public String  splitMergeEvidence;
        public String  state;
        public Boolean metadataOverlapFlag;
        public String  evidenceSuffix;   // Apex-appended note (Needs Merge with elevated Ambiguity), else ''
    }

    public class Gate3Result {
        public Integer businessValueCriteriaMet;
        public Integer businessValueScore;
        public Boolean businessValueOverrideFired;
        public Integer deploymentRiskCriteriaMet;
        public Integer deploymentRiskScore;
        public Boolean deploymentRiskOverrideFired;
        public String  state;
        public String  subReason;        // only for Backlog-Hold, else null
        public String  evidencePrefix;   // '[Pending Gate 2 resolution] ' / '[Sprint readiness gap] ' / ''
    }

    public class Confidence {
        public Integer sum1;             // 0-25
        public Integer sum2;             // 0-15
        public Integer sum3;             // 0-15
        public Integer overallNumerator; // Overall_Confidence = overallNumerator / 225
        public Decimal c1;               // rounded to 4 dp, for storage/display only
        public Decimal c2;
        public Decimal c3;
        public Decimal overall;
        /** Exact test: Overall_Confidence >= num/den (no floating point). */
        public Boolean atLeast(Integer num, Integer den) {
            return overallNumerator * den >= num * 225;
        }
    }

    public class Recommendation {
        public String action;            // Enter Sprint / Refine First / Hold / Discard/Reassess
        public String ruleId;            // R1..R8
        public String ruledescpription;
        public String triggeringRule;    // 'R1 - Gate 1 = Needs Rewrite' (what Gate 4's prompt receives)
        public String nextStep;          // routing hint for the PO
        public String subReason;         // R4 only
    }

    public class Evaluation {
        public Gate1Result gate1;
        public Gate2Result gate2;
        public Gate3Result gate3;
        public Confidence  confidence;
        public Recommendation recommendation;
    }

    // =====================================================================================
    // Validation helpers
    // =====================================================================================

    private static Integer requireScore(Integer value, String field) {
        if (value == null) {
            throw new ScoringException('Missing score: ' + field);
        }
        if (value < 0 || value > 5) {
            throw new ScoringException('Score out of range 0-5 for ' + field + ': ' + value);
        }
        return value;
    }

    private static Boolean requireBool(Boolean value, String field) {
        if (value == null) {
            throw new ScoringException('Missing checklist boolean: ' + field);
        }
        return value;
    }

    private static Integer b2i(Boolean b) {
        return b ? 1 : 0;
    }

    // =====================================================================================
    // Gate 1
    // =====================================================================================

    public static Gate1Result deriveGate1(Gate1Scores s) {
        if (s == null) { throw new ScoringException('Gate 1 scores missing'); }
        Integer[] all = new Integer[] {
            requireScore(s.completeness, 'completeness'),
            requireScore(s.clarity, 'clarity'),
            requireScore(s.acceptanceCriteria, 'acceptance_criteria'),
            requireScore(s.invest, 'invest_compliance'),
            requireScore(s.technicalApproach, 'technical_approach_clarity')
        };
        Integer total = 0;
        Integer lowest = 5;
        for (Integer v : all) {
            total += v;
            if (v < lowest) { lowest = v; }
        }
        Gate1Result r = new Gate1Result();
        r.rawSum = total;
        r.lowestScore = lowest;
        r.state = (lowest >= 3) ? G1_PASS : G1_NEEDS_REWRITE;
        return r;
    }

    // =====================================================================================
    // Gate 2
    // =====================================================================================

    /** Split/Merge signal anchors evaluated from 5 down to 0, first match wins (Gate 2 spec v1.1). */
    public static Integer splitMergeSignal(Integer dr, Integer amb) {
        requireScore(dr, 'duplicate_risk');
        requireScore(amb, 'ambiguity');
        if (dr == 5 && amb >= 3) { return 5; }
        if (dr >= 4)             { return 4; }
        if (amb >= 4)            { return 3; }
        if (amb == 3)            { return 2; }
        if (dr >= 2 || amb == 2) { return 1; }
        return 0;
    }

    private static String splitMergeAction(Integer signal) {
        if (signal == 5) { return 'merge with the near-duplicate AND disentangle internally - flag for manual review'; }
        if (signal == 4) { return 'recommend merge with the near-duplicate story'; }
        if (signal == 3) { return 'recommend split into separate stories'; }
        if (signal == 2) { return 'split plausible but not urgent'; }
        if (signal == 1) { return 'weak signal, not actionable yet'; }
        return 'no split/merge signal';
    }

    public static Gate2Result deriveGate2(Gate2Scores s) {
        if (s == null) { throw new ScoringException('Gate 2 scores missing'); }
        Integer dr  = requireScore(s.duplicateRisk, 'duplicate_risk');
        Integer amb = requireScore(s.ambiguity, 'ambiguity');
        Integer mor = requireScore(s.metadataOverlapRisk, 'metadata_overlap_risk');

        Gate2Result r = new Gate2Result();
        r.splitMergeSignal = splitMergeSignal(dr, amb);
        r.splitMergeEvidence = 'Duplicate risk=' + dr + ', Ambiguity=' + amb + ' -> ' + splitMergeAction(r.splitMergeSignal);

        // Priority-ordered rule table, first match wins; merge outranks split.
        if (dr >= 4)        { r.state = G2_NEEDS_MERGE; }
        else if (amb >= 4)  { r.state = G2_NEEDS_SPLIT; }
        else if (dr == 3)   { r.state = G2_DUP_FLAGGED; }
        else                { r.state = G2_CLEAN; }

        r.metadataOverlapFlag = (mor >= 3);
        r.evidenceSuffix = (r.state == G2_NEEDS_MERGE && amb >= 3)
            ? ' (Ambiguity also elevated: re-run Gate 2 on the merged story)'
            : '';
        return r;
    }

    // =====================================================================================
    // Gate 3
    // =====================================================================================

    /** Fixed criteria-met -> score mapping (Decision #30): 0->0, 1->1, 2->3, 3->4, 4->5. */
    public static Integer scoreFromCriteriaMet(Integer met) {
        if (met == null || met < 0 || met > 4) {
            throw new ScoringException('criteria-met count must be 0-4, got: ' + met);
        }
        if (met == 0) { return 0; }
        if (met == 1) { return 1; }
        if (met == 2) { return 3; }
        if (met == 3) { return 4; }
        return 5;
    }

    public static Gate3Result deriveGate3(Gate3Inputs in3, String gate2State) {
        if (in3 == null) { throw new ScoringException('Gate 3 inputs missing'); }
        if (gate2State == null || !VALID_G2_STATES.contains(gate2State)) {
            throw new ScoringException('Invalid Gate 2 state passed to Gate 3: ' + gate2State);
        }
        Integer dep = requireScore(in3.dependency, 'dependency');
        Integer sr  = requireScore(in3.sprintReadiness, 'sprint_readiness');
        if (in3.driverCategory == null || !VALID_DRIVERS.contains(in3.driverCategory)) {
            throw new ScoringException('Invalid driver_category: ' + in3.driverCategory);
        }
        Boolean core   = requireBool(in3.coreScope, 'core_scope');
        Boolean urgent = requireBool(in3.urgencySignal, 'urgency_signal');
        Boolean quant  = requireBool(in3.quantifiableImpact, 'quantifiable_impact');
        Boolean bulkk  = requireBool(in3.bulkVolume, 'bulkk_volume');
        Boolean callout= requireBool(in3.calloutIntegration, 'callout_integration');
        Boolean recur  = requireBool(in3.recursiveAutomation, 'recursive_automation');
        Boolean env    = requireBool(in3.environmentReadiness, 'environment_readiness');

        Gate3Result r = new Gate3Result();

        // Business Value: criterion (a) is met when driver_category != None
        r.businessValueCriteriaMet = b2i(in3.driverCategory != DRIVER_NONE) + b2i(core) + b2i(urgent) + b2i(quant);
        Boolean bvOverride = (in3.driverCategory == DRIVER_COMPLIANCE || in3.driverCategory == DRIVER_RISK) && urgent;
        r.businessValueOverrideFired = bvOverride;
        r.businessValueScore = bvOverride ? 5 : scoreFromCriteriaMet(r.businessValueCriteriaMet);

        // Deployment/Technical Risk
        r.deploymentRiskCriteriaMet = b2i(bulkk) + b2i(callout) + b2i(recur) + b2i(env);
        Boolean dtrOverride = bulkk && callout;
        r.deploymentRiskOverrideFired = dtrOverride;
        r.deploymentRiskScore = dtrOverride ? 5 : scoreFromCriteriaMet(r.deploymentRiskCriteriaMet);

        // Output-state rule table (priority-ordered, first match wins)
        r.subReason = null;
        r.evidencePrefix = '';
        if (gate2State == G2_NEEDS_SPLIT || gate2State == G2_NEEDS_MERGE) {
            r.state = G3_BACKLOG_HOLD;
            r.subReason = SUBREASON_PENDING_G2;
        } else if (r.deploymentRiskScore >= 4) {
            r.state = G3_ARCH_REVIEW;
        } else if (dep >= 4) {
            r.state = G3_BLOCKED;
        } else if (sr <= 2) {
            r.state = G3_BACKLOG_HOLD;
            r.subReason = SUBREASON_READINESS;
        } else {
            r.state = G3_SPRINT_READY;
        }
        if (r.subReason != null) {
            r.evidencePrefix = '[' + r.subReason + '] ';
        }
        return r;
    }

    // =====================================================================================
    // Confidence (Section 7.1-7.2, Decisions #22 and #26)
    // =====================================================================================

    public static Confidence confidenceFromSums(Integer sum1, Integer sum2, Integer sum3) {
        if (sum1 == null || sum1 < 0 || sum1 > 25) { throw new ScoringException('sum1 out of range 0-25: ' + sum1); }
        if (sum2 == null || sum2 < 0 || sum2 > 15) { throw new ScoringException('sum2 out of range 0-15: ' + sum2); }
        if (sum3 == null || sum3 < 0 || sum3 > 15) { throw new ScoringException('sum3 out of range 0-15: ' + sum3); }
        Confidence c = new Confidence();
        c.sum1 = sum1;
        c.sum2 = sum2;
        c.sum3 = sum3;
        c.overallNumerator = 3 * sum1 + 5 * sum2 + 5 * sum3;
        Decimal d1 = sum1;
        Decimal d2 = sum2;
        Decimal d3 = sum3;
        Decimal dn = c.overallNumerator;
        c.c1 = d1.divide(25, 4, RoundingMode.HALF_UP);
        c.c2 = d2.divide(15, 4, RoundingMode.HALF_UP);
        c.c3 = d3.divide(15, 4, RoundingMode.HALF_UP);
        c.overall = dn.divide(225, 4, RoundingMode.HALF_UP);
        return c;
    }

    /**
     * C1 = (Completeness + Clarity + AC + INVEST + TechApproach) / 25
     * C2 = ((5-DupRisk) + (5-Ambiguity) + (5-MetadataOverlapRisk)) / 15
     * C3 = ((5-Dependency) + SprintReadiness + (5-DeploymentTechnicalRisk)) / 15
     * Split/Merge Signal and Business Value are excluded (Decision #26).
     */
    public static Confidence computeConfidence(Gate1Scores g1, Gate2Scores g2, Gate3Inputs g3, Gate3Result g3Result) {
        Gate1Result r1 = deriveGate1(g1);
        Integer dr  = requireScore(g2.duplicateRisk, 'duplicate_risk');
        Integer amb = requireScore(g2.ambiguity, 'ambiguity');
        Integer mor = requireScore(g2.metadataOverlapRisk, 'metadata_overlap_risk');
        Integer dep = requireScore(g3.dependency, 'dependency');
        Integer sr  = requireScore(g3.sprintReadiness, 'sprint_readiness');
        Integer sum2 = (5 - dr) + (5 - amb) + (5 - mor);
        Integer sum3 = (5 - dep) + sr + (5 - g3Result.deploymentRiskScore);
        return confidenceFromSums(r1.rawSum, sum2, sum3);
    }

    // =====================================================================================
    // Gate 4 recommendation (Section 7.3, rule table R1-R8, first match wins)
    // =====================================================================================

    private static Recommendation rule(String action, String id, String descp, String next, String sub) {
        Recommendation r = new Recommendation();
        r.action = action;
        r.ruleId = id;
        r.ruledescpription = descp;
        r.triggeringRule = id + ' - ' + descp;
        r.nextStep = next;
        r.subReason = sub;
        return r;
    }

    public static Recommendation recommend(String g1State, String g2State, String g3State,
                                           String g3SubReason, Confidence c) {
        if (g1State == null || !VALID_G1_STATES.contains(g1State)) { throw new ScoringException('Invalid Gate 1 state: ' + g1State); }
        if (g2State == null || !VALID_G2_STATES.contains(g2State)) { throw new ScoringException('Invalid Gate 2 state: ' + g2State); }
        if (g3State == null || !VALID_G3_STATES.contains(g3State)) { throw new ScoringException('Invalid Gate 3 state: ' + g3State); }
        if (c == null) { throw new ScoringException('Confidence missing'); }

        if (g1State == G1_NEEDS_REWRITE) {
            return rule(REC_REFINE_FIRST, 'R1', 'Gate 1 = Needs Rewrite',
                        'Route to the suggested rewrite; Gate 2 and Gate 3 results are provisional', null);
        }
        if (g3State == G3_ARCH_REVIEW) {
            return rule(REC_HOLD, 'R2', 'Gate 3 = Needs-Architecture-Review',
                        'Architecture/Tech Lead review', null);
        }
        if (g3State == G3_BLOCKED) {
            return rule(REC_HOLD, 'R3', 'Gate 3 = Blocked', 'Dependency resolution', null);
        }
        if (g3State == G3_BACKLOG_HOLD) {
            return rule(REC_REFINE_FIRST, 'R4', 'Gate 3 = Backlog-Hold',
                        'Resolve the Backlog-Hold sub-reason, then re-assess', g3SubReason);
        }
        // From here Gate 3 = Sprint-Ready
        if (g2State == G2_DUP_FLAGGED && c.atLeast(3, 4)) {
            return rule(REC_REFINE_FIRST, 'R5', 'Gate 3 = Sprint-Ready AND Gate 2 = Duplicate-flagged AND OC >= 0.75',
                        'Product Owner judgment on the flagged duplicate', null);
        }
        if (c.atLeast(3, 4)) {
            return rule(REC_ENTER_SPRINT, 'R6', 'Gate 3 = Sprint-Ready AND OC >= 0.75', null, null);
        }
        if (c.atLeast(1, 2)) {
            return rule(REC_REFINE_FIRST, 'R7', 'Gate 3 = Sprint-Ready AND 0.5 <= OC < 0.75',
                        'Refine the borderline dimensions before entering a sprint', null);
        }
        return rule(REC_DISCARD, 'R8', 'Gate 3 = Sprint-Ready AND OC < 0.5',
                    'Reassess whether this story should proceed', null);
    }

    // =====================================================================================
    // Convenience: full evaluation from raw LLM-returned values
    // =====================================================================================

    public static Evaluation evaluate(Gate1Scores g1, Gate2Scores g2, Gate3Inputs g3) {
        Evaluation e = new Evaluation();
        e.gate1 = deriveGate1(g1);
        e.gate2 = deriveGate2(g2);
        e.gate3 = deriveGate3(g3, e.gate2.state);
        e.confidence = computeConfidence(g1, g2, g3, e.gate3);
        e.recommendation = recommend(e.gate1.state, e.gate2.state, e.gate3.state, e.gate3.subReason, e.confidence);
        return e;
    }
}
