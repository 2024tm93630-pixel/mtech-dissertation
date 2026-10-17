/**
 * Unit tests for ScoringEngine. No LLM, SOQL or DML involved — these validate the deterministic
 * rules of Blueprint v1.1 Section 7 and can be run before any Gemini integration exists.
 */
@IsTest
private class ScoringEngineTest {

    // ---------- helpers ----------
    private static ScoringEngine.Gate3Inputs g3(Integer dep, Integer sr) {
        ScoringEngine.Gate3Inputs i = new ScoringEngine.Gate3Inputs();
        i.dependency = dep;
        i.sprintReadiness = sr;
        i.driverCategory = 'None';
        i.coreScope = false;
        i.urgencySignal = false;
        i.quantifiableImpact = false;
        i.bulkVolume = false;
        i.calloutIntegration = false;
        i.recursiveAutomation = false;
        i.environmentReadiness = false;
        return i;
    }

    private static ScoringEngine.Gate1Scores perfectG1() { return new ScoringEngine.Gate1Scores(5, 5, 5, 5, 5); }
    private static ScoringEngine.Gate2Scores cleanG2()   { return new ScoringEngine.Gate2Scores(0, 0, 0); }

    // ---------- Gate 1 ----------
    @IsTest static void gate1_passRequiresAllScoresAtLeastThree() {
        System.assertEquals('Pass', ScoringEngine.deriveGate1(new ScoringEngine.Gate1Scores(3, 3, 3, 3, 3)).state);
        System.assertEquals('Needs Rewrite', ScoringEngine.deriveGate1(new ScoringEngine.Gate1Scores(5, 5, 2, 5, 5)).state);
        System.assertEquals('Needs Rewrite', ScoringEngine.deriveGate1(new ScoringEngine.Gate1Scores(0, 5, 5, 5, 5)).state);
        ScoringEngine.Gate1Result r = ScoringEngine.deriveGate1(new ScoringEngine.Gate1Scores(4, 3, 5, 4, 3));
        System.assertEquals(19, r.rawSum);
        System.assertEquals(3, r.lowestScore);
    }

    // ---------- Gate 2 ----------
    @IsTest static void gate2_splitMergeSignalAnchors() {
        // {duplicateRisk, ambiguity, expectedSignal}
        Integer[][] cases = new Integer[][] {
            new Integer[]{0,0,0}, new Integer[]{1,1,0},
            new Integer[]{2,0,1}, new Integer[]{3,0,1}, new Integer[]{0,2,1},
            new Integer[]{0,3,2}, new Integer[]{3,3,2},
            new Integer[]{0,4,3}, new Integer[]{2,5,3},
            new Integer[]{4,0,4}, new Integer[]{5,2,4}, new Integer[]{4,4,4},
            new Integer[]{5,3,5}, new Integer[]{5,5,5}
        };
        for (Integer[] c : cases) {
            System.assertEquals(c[2], ScoringEngine.splitMergeSignal(c[0], c[1]),
                'DR=' + c[0] + ' AMB=' + c[1]);
        }
    }

    @IsTest static void gate2_outputStateRuleTable() {
        System.assertEquals('Clean',             ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(0, 0, 0)).state);
        System.assertEquals('Clean',             ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(2, 3, 0)).state);
        System.assertEquals('Duplicate-flagged', ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(3, 0, 0)).state);
        System.assertEquals('Duplicate-flagged', ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(3, 3, 0)).state);
        System.assertEquals('Needs Split',       ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(0, 4, 0)).state);
        System.assertEquals('Needs Split',       ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(3, 4, 0)).state, 'Split outranks Duplicate-flagged');
        System.assertEquals('Needs Merge',       ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(4, 0, 0)).state);
        System.assertEquals('Needs Merge',       ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(5, 5, 0)).state, 'Merge outranks Split');
    }

    @IsTest static void gate2_everyScoreCombinationMapsToExactlyOneState() {
        Set<String> valid = new Set<String>{ 'Clean', 'Duplicate-flagged', 'Needs Split', 'Needs Merge' };
        for (Integer dr = 0; dr <= 5; dr++) {
            for (Integer amb = 0; amb <= 5; amb++) {
                ScoringEngine.Gate2Result r = ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(dr, amb, 0));
                System.assert(valid.contains(r.state), 'No valid state for DR=' + dr + ' AMB=' + amb);
                System.assert(r.splitMergeSignal >= 0 && r.splitMergeSignal <= 5);
            }
        }
    }

    @IsTest static void gate2_metadataOverlapFlagBoundary() {
        System.assertEquals(false, ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(0, 0, 2)).metadataOverlapFlag);
        System.assertEquals(true,  ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(0, 0, 3)).metadataOverlapFlag);
        // the flag is independent of the state
        ScoringEngine.Gate2Result r = ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(0, 0, 4));
        System.assertEquals('Clean', r.state);
        System.assertEquals(true, r.metadataOverlapFlag);
    }

    @IsTest static void gate2_needsMergeAppendsNoteOnlyWhenAmbiguityElevated() {
        System.assert(ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(4, 3, 0)).evidenceSuffix.contains('re-run Gate 2'));
        System.assertEquals('', ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(4, 2, 0)).evidenceSuffix);
        System.assertEquals('', ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(0, 4, 0)).evidenceSuffix);
    }

    // ---------- Gate 3 checklist scoring ----------
    @IsTest static void gate3_criteriaMetMapping() {
        System.assertEquals(0, ScoringEngine.scoreFromCriteriaMet(0));
        System.assertEquals(1, ScoringEngine.scoreFromCriteriaMet(1));
        System.assertEquals(3, ScoringEngine.scoreFromCriteriaMet(2));
        System.assertEquals(4, ScoringEngine.scoreFromCriteriaMet(3));
        System.assertEquals(5, ScoringEngine.scoreFromCriteriaMet(4));
    }

    @IsTest static void gate3_businessValueScoreAndOverride() {
        ScoringEngine.Gate3Inputs i = g3(0, 5);
        i.driverCategory = 'Operational Efficiency';
        i.coreScope = true;
        i.quantifiableImpact = true;                       // 3 criteria met
        ScoringEngine.Gate3Result r = ScoringEngine.deriveGate3(i, 'Clean');
        System.assertEquals(3, r.businessValueCriteriaMet);
        System.assertEquals(4, r.businessValueScore);
        System.assertEquals(false, r.businessValueOverrideFired);

        // Compliance driver WITHOUT urgency -> no override
        i = g3(0, 5);
        i.driverCategory = 'Compliance/Regulatory';
        r = ScoringEngine.deriveGate3(i, 'Clean');
        System.assertEquals(1, r.businessValueScore);
        System.assertEquals(false, r.businessValueOverrideFired);

        // Compliance driver WITH urgency -> override to 5 although only 2 criteria met
        i.urgencySignal = true;
        r = ScoringEngine.deriveGate3(i, 'Clean');
        System.assertEquals(2, r.businessValueCriteriaMet);
        System.assertEquals(5, r.businessValueScore);
        System.assertEquals(true, r.businessValueOverrideFired);

        // Revenue driver with urgency is NOT an override driver
        i = g3(0, 5);
        i.driverCategory = 'Revenue';
        i.urgencySignal = true;
        r = ScoringEngine.deriveGate3(i, 'Clean');
        System.assertEquals(3, r.businessValueScore);
        System.assertEquals(false, r.businessValueOverrideFired);
    }

    @IsTest static void gate3_deploymentRiskScoreAndBulkCalloutOverride() {
        ScoringEngine.Gate3Inputs i = g3(0, 5);
        i.bulkVolume = true;
        i.environmentReadiness = true;                     // 2 met, no override -> 3
        ScoringEngine.Gate3Result r = ScoringEngine.deriveGate3(i, 'Clean');
        System.assertEquals(3, r.deploymentRiskScore);
        System.assertEquals(false, r.deploymentRiskOverrideFired);
        System.assertEquals('Sprint-Ready', r.state, 'score 3 must not trigger architecture review');

        i = g3(0, 5);
        i.bulkVolume = true;
        i.calloutIntegration = true;                       // 2 met but override -> 5
        r = ScoringEngine.deriveGate3(i, 'Clean');
        System.assertEquals(2, r.deploymentRiskCriteriaMet);
        System.assertEquals(5, r.deploymentRiskScore);
        System.assertEquals(true, r.deploymentRiskOverrideFired);
        System.assertEquals('Needs-Architecture-Review', r.state);

        i = g3(0, 5);
        i.bulkVolume = true;
        i.recursiveAutomation = true;
        i.environmentReadiness = true;                     // 3 met -> 4 -> architecture review
        r = ScoringEngine.deriveGate3(i, 'Clean');
        System.assertEquals(4, r.deploymentRiskScore);
        System.assertEquals('Needs-Architecture-Review', r.state);
    }

    // ---------- Gate 3 state rule table ----------
    @IsTest static void gate3_unresolvedGate2StateOutranksEverything() {
        ScoringEngine.Gate3Inputs i = g3(5, 0);
        i.bulkVolume = true;
        i.calloutIntegration = true;
        for (String g2 : new String[] { 'Needs Split', 'Needs Merge' }) {
            ScoringEngine.Gate3Result r = ScoringEngine.deriveGate3(i, g2);
            System.assertEquals('Backlog-Hold', r.state);
            System.assertEquals('Pending Gate 2 resolution', r.subReason);
            System.assertEquals('[Pending Gate 2 resolution] ', r.evidencePrefix);
        }
    }

    @IsTest static void gate3_priorityOrderAfterGate2() {
        // Architecture review outranks Blocked
        ScoringEngine.Gate3Inputs i = g3(5, 5);
        i.bulkVolume = true;
        i.calloutIntegration = true;
        System.assertEquals('Needs-Architecture-Review', ScoringEngine.deriveGate3(i, 'Clean').state);

        // Blocked outranks the readiness-gap Backlog-Hold
        System.assertEquals('Blocked', ScoringEngine.deriveGate3(g3(4, 2), 'Clean').state);
        System.assertEquals('Sprint-Ready', ScoringEngine.deriveGate3(g3(3, 3), 'Clean').state, 'Dependency 3 is not blocking');

        // Readiness gap
        ScoringEngine.Gate3Result r = ScoringEngine.deriveGate3(g3(3, 2), 'Duplicate-flagged');
        System.assertEquals('Backlog-Hold', r.state);
        System.assertEquals('Sprint readiness gap', r.subReason);
        System.assertEquals('[Sprint readiness gap] ', r.evidencePrefix);

        // Duplicate-flagged does not itself block Gate 3
        System.assertEquals('Sprint-Ready', ScoringEngine.deriveGate3(g3(0, 5), 'Duplicate-flagged').state);
    }

    // ---------- Confidence ----------
    @IsTest static void confidence_perfectAndWorstStories() {
        ScoringEngine.Evaluation best = ScoringEngine.evaluate(perfectG1(), cleanG2(), g3(0, 5));
        System.assertEquals(1.0000, best.confidence.c1);
        System.assertEquals(1.0000, best.confidence.c2);
        System.assertEquals(1.0000, best.confidence.c3);
        System.assertEquals(1.0000, best.confidence.overall, 'a perfect story must score exactly 1.0');

        ScoringEngine.Confidence worst = ScoringEngine.confidenceFromSums(0, 0, 0);
        System.assertEquals(0.0000, worst.overall);
    }

    @IsTest static void confidence_formulasWithDirectionInversion() {
        // C1 = 20/25 = 0.8 ; C2 = (4+4+4)/15 = 0.8 ; C3 = (4 + 4 + 4)/15 = 0.8
        ScoringEngine.Gate3Inputs i = g3(1, 4);
        i.environmentReadiness = true;                     // 1 criterion -> deployment risk 1
        ScoringEngine.Evaluation e = ScoringEngine.evaluate(
            new ScoringEngine.Gate1Scores(4, 4, 4, 4, 4), new ScoringEngine.Gate2Scores(1, 1, 1), i);
        System.assertEquals(0.8000, e.confidence.c1);
        System.assertEquals(0.8000, e.confidence.c2);
        System.assertEquals(0.8000, e.confidence.c3);
        System.assertEquals(0.8000, e.confidence.overall);
    }

    @IsTest static void confidence_businessValueAndSplitMergeDoNotAffectConfidence() {
        ScoringEngine.Gate3Inputs low  = g3(0, 5);
        ScoringEngine.Gate3Inputs high = g3(0, 5);
        high.driverCategory = 'Risk Mitigation';
        high.urgencySignal = true;
        high.coreScope = true;
        high.quantifiableImpact = true;
        Decimal a = ScoringEngine.evaluate(perfectG1(), cleanG2(), low).confidence.overall;
        Decimal b = ScoringEngine.evaluate(perfectG1(), cleanG2(), high).confidence.overall;
        System.assertEquals(a, b, 'Business Value must not feed Overall_Confidence (Decision #26)');
    }

    @IsTest static void confidence_exactBoundariesAtThreeQuartersAndOneHalf() {
        // numerator = 3*s1 + 5*s2 + 5*s3 ; OC = numerator / 225
        System.assertEquals(169, ScoringEngine.confidenceFromSums(8, 15, 14).overallNumerator);
        System.assertEquals(true,  ScoringEngine.confidenceFromSums(8, 15, 14).atLeast(3, 4));   // 0.7511
        System.assertEquals(168, ScoringEngine.confidenceFromSums(6, 15, 15).overallNumerator);
        System.assertEquals(false, ScoringEngine.confidenceFromSums(6, 15, 15).atLeast(3, 4));   // 0.7467
        System.assertEquals(true,  ScoringEngine.confidenceFromSums(16, 7, 6).atLeast(1, 2));    // 113 -> 0.5022
        System.assertEquals(false, ScoringEngine.confidenceFromSums(14, 7, 7).atLeast(1, 2));    // 112 -> 0.4978
    }

    // ---------- Gate 4 rule table R1-R8 ----------
    @IsTest static void recommend_allRulesFireAndPriorityHolds() {
        ScoringEngine.Confidence hi  = ScoringEngine.confidenceFromSums(25, 15, 15);
        ScoringEngine.Confidence mid = ScoringEngine.confidenceFromSums(6, 15, 15);    // 0.7467
        ScoringEngine.Confidence lo  = ScoringEngine.confidenceFromSums(14, 7, 7);     // 0.4978

        ScoringEngine.Recommendation r;
        r = ScoringEngine.recommend('Needs Rewrite', 'Clean', 'Sprint-Ready', null, hi);
        System.assertEquals('R1', r.ruleId); System.assertEquals('Refine First', r.action);

        r = ScoringEngine.recommend('Needs Rewrite', 'Needs Merge', 'Blocked', null, hi);
        System.assertEquals('R1', r.ruleId, 'Gate 1 failure outranks every Gate 3 state');

        r = ScoringEngine.recommend('Pass', 'Clean', 'Needs-Architecture-Review', null, hi);
        System.assertEquals('R2', r.ruleId); System.assertEquals('Hold', r.action);

        r = ScoringEngine.recommend('Pass', 'Clean', 'Blocked', null, hi);
        System.assertEquals('R3', r.ruleId); System.assertEquals('Hold', r.action);

        r = ScoringEngine.recommend('Pass', 'Needs Split', 'Backlog-Hold', 'Pending Gate 2 resolution', hi);
        System.assertEquals('R4', r.ruleId); System.assertEquals('Refine First', r.action);
        System.assertEquals('Pending Gate 2 resolution', r.subReason);

        r = ScoringEngine.recommend('Pass', 'Duplicate-flagged', 'Sprint-Ready', null, hi);
        System.assertEquals('R5', r.ruleId); System.assertEquals('Refine First', r.action);

        r = ScoringEngine.recommend('Pass', 'Duplicate-flagged', 'Sprint-Ready', null, mid);
        System.assertEquals('R7', r.ruleId, 'R5 only downgrades what would otherwise be Enter Sprint');

        r = ScoringEngine.recommend('Pass', 'Clean', 'Sprint-Ready', null, hi);
        System.assertEquals('R6', r.ruleId); System.assertEquals('Enter Sprint', r.action);

        r = ScoringEngine.recommend('Pass', 'Clean', 'Sprint-Ready', null, mid);
        System.assertEquals('R7', r.ruleId); System.assertEquals('Refine First', r.action);

        r = ScoringEngine.recommend('Pass', 'Clean', 'Sprint-Ready', null, lo);
        System.assertEquals('R8', r.ruleId); System.assertEquals('Discard/Reassess', r.action);
        System.assert(r.triggeringRule.startsWith('R8'));
    }

    // ---------- End-to-end derivations ----------
    @IsTest static void evaluate_wellFormedStoryEntersSprint() {
        ScoringEngine.Evaluation e = ScoringEngine.evaluate(perfectG1(), cleanG2(), g3(0, 5));
        System.assertEquals('Pass', e.gate1.state);
        System.assertEquals('Clean', e.gate2.state);
        System.assertEquals('Sprint-Ready', e.gate3.state);
        System.assertEquals('R6', e.recommendation.ruleId);
        System.assertEquals('Enter Sprint', e.recommendation.action);
    }

    @IsTest static void evaluate_decision29Regression_gate1FailureCannotEnterSprint() {
        // One Gate 1 dimension at 2, four at 5 -> C1 = 0.88 (high), but Gate 1 = Needs Rewrite
        ScoringEngine.Evaluation e = ScoringEngine.evaluate(
            new ScoringEngine.Gate1Scores(5, 5, 2, 5, 5), cleanG2(), g3(0, 5));
        System.assertEquals(0.8800, e.confidence.c1);
        System.assertEquals(0.9600, e.confidence.overall);
        System.assertEquals('Needs Rewrite', e.gate1.state);
        System.assertEquals('R1', e.recommendation.ruleId);
        System.assertNotEquals('Enter Sprint', e.recommendation.action);
    }

    @IsTest static void evaluate_bundledStoryRoutesToRefinementNotSprint() {
        // Flow + Apex bundle with conflated AC: Ambiguity 4 -> Needs Split -> Backlog-Hold -> R4
        ScoringEngine.Evaluation e = ScoringEngine.evaluate(
            perfectG1(), new ScoringEngine.Gate2Scores(1, 4, 0), g3(0, 5));
        System.assertEquals('Needs Split', e.gate2.state);
        System.assertEquals('Backlog-Hold', e.gate3.state);
        System.assertEquals('R4', e.recommendation.ruleId);
        System.assertEquals('Pending Gate 2 resolution', e.recommendation.subReason);
    }

    // ---------- Input validation (guards against malformed LLM output) ----------
    @IsTest static void validation_rejectsOutOfRangeMissingAndInvalidValues() {
        Boolean threw = false;
        try { ScoringEngine.deriveGate1(new ScoringEngine.Gate1Scores(6, 5, 5, 5, 5)); }
        catch (ScoringEngine.ScoringException e) { threw = true; }
        System.assert(threw, 'score 6 must be rejected');

        threw = false;
        try { ScoringEngine.deriveGate1(new ScoringEngine.Gate1Scores(5, 5, null, 5, 5)); }
        catch (ScoringEngine.ScoringException e) { threw = true; }
        System.assert(threw, 'missing score must be rejected');

        threw = false;
        try { ScoringEngine.deriveGate2(new ScoringEngine.Gate2Scores(0, -1, 0)); }
        catch (ScoringEngine.ScoringException e) { threw = true; }
        System.assert(threw, 'negative score must be rejected');

        threw = false;
        ScoringEngine.Gate3Inputs bad = g3(0, 5);
        bad.driverCategory = 'Vibes';
        try { ScoringEngine.deriveGate3(bad, 'Clean'); }
        catch (ScoringEngine.ScoringException e) { threw = true; }
        System.assert(threw, 'unknown driver_category must be rejected');

        threw = false;
        bad = g3(0, 5);
        bad.urgencySignal = null;
        try { ScoringEngine.deriveGate3(bad, 'Clean'); }
        catch (ScoringEngine.ScoringException e) { threw = true; }
        System.assert(threw, 'missing checklist boolean must be rejected, not silently treated as false');

        threw = false;
        try { ScoringEngine.deriveGate3(g3(0, 5), 'Maybe'); }
        catch (ScoringEngine.ScoringException e) { threw = true; }
        System.assert(threw, 'invalid Gate 2 state must be rejected');

        threw = false;
        try { ScoringEngine.recommend('Pass', 'Clean', 'Sprint-Ready', null, null); }
        catch (ScoringEngine.ScoringException e) { threw = true; }
        System.assert(threw, 'missing confidence must be rejected');
    }
}
