"""Single source for the HF, lipid and CAD data dictionaries.
Generates: SQL seed (variable_definitions + protocol_variables), CSV files,
and markdown tables for the spec doc."""
import csv, json, sys, os

OUT = sys.argv[1]

# (code, category, label, type, unit, allowed, min, max, source_kind, source/derivation, visits)
# visits: dict visit_code -> 'M' mandatory | 'C' conditional | 'O' optional
HF_VISITS = ['BL', 'M1', 'M3', 'M6', 'M12', 'ANNUAL']
LP_VISITS = ['BL', 'W6_12', 'M6', 'M12', 'ANNUAL']

def v(spec, visits):
    out = {}
    for part in spec.split():
        k, r = part.split('=')
        if k == '*':
            for x in visits: out[x] = r
        else:
            out[k] = r
    return out

YN = None
NYHA = [('I', 'NYHA I'), ('II', 'NYHA II'), ('III', 'NYHA III'), ('IV', 'NYHA IV')]
SEX = [('male', 'Male'), ('female', 'Female'), ('other', 'Other'), ('unknown', 'Unknown')]
AET = [(x, x.replace('_', ' ')) for x in ['ischaemic', 'dilated_non_ischaemic', 'hypertensive', 'valvular',
       'rheumatic_valvular', 'tachycardia_induced', 'peripartum', 'myocarditis', 'infiltrative', 'hypertrophic',
       'chemotherapy_related', 'alcohol_related', 'congenital', 'other', 'unknown']]
PHEN = [(x, x) for x in ['HFrEF', 'HFmrEF', 'HFpEF', 'HFimpEF']]
RVF = [(x, x.replace('_', ' ')) for x in ['normal', 'mildly_reduced', 'moderately_reduced', 'severely_reduced']]
CONG = [(x, x) for x in ['euvolaemic', 'mild', 'moderate', 'severe']]
HFSTAT = [('newly_diagnosed', 'Newly diagnosed'), ('prevalent', 'Prevalent at enrolment'),
          ('post_discharge', 'Referred after HF hospital discharge')]
GDMT_STATUS = [(x, x.replace('_', ' ')) for x in ['at_target', 'below_target_uptitrating',
               'below_target_max_tolerated', 'not_prescribed', 'not_indicated']]
GDMT_REASON = [(x, x.replace('_', ' ')) for x in ['contraindication', 'intolerance', 'hypotension',
               'hyperkalaemia', 'renal_dysfunction', 'bradycardia', 'worsening_hf', 'patient_refusal',
               'financial', 'drug_unavailable', 'titration_in_progress', 'recently_initiated',
               'not_indicated_for_phenotype', 'other']]
DEVICES = [(x, x.replace('_', '-')) for x in ['ICD', 'CRT_P', 'CRT_D', 'PPM', 'CSP']]
VITAL = [('alive', 'Alive'), ('dead', 'Dead'), ('unknown', 'Unknown / lost')]
DIAST = [(x, x.replace('_', ' ')) for x in ['normal', 'grade_I', 'grade_II', 'grade_III', 'indeterminate']]

HF = [
 # Demographics
 ('age_at_index','Demographics','Age at index date','integer','years',None,18,110,'calculated','calc.age_at_index: registration DOB to enrolment index date','BL=M'),
 ('sex','Demographics','Sex','coded',None,SEX,None,None,'emr_derived','emr.registration_sex: patient_registrations.sex','BL=M'),
 ('height_cm','Demographics','Height','numeric','cm',None,100,230,'emr_derived','emr.vitals_latest: vital_signs.height_cm, latest in 365 d','BL=M'),
 ('weight_kg','Demographics','Weight','numeric','kg',None,25,250,'emr_derived','emr.vitals_in_window: vital_signs.weight_kg in visit window','*=M'),
 ('bmi','Demographics','Body-mass index','numeric','kg/m2',None,10,70,'calculated','calc.bmi: weight / height^2','*=M'),
 # Enrolment
 ('hf_status_at_enrolment','Enrolment','HF status at enrolment','coded',None,HFSTAT,None,None,'entered',None,'BL=M'),
 ('hf_diagnosis_date','Enrolment','Date HF first diagnosed (day, month or year)','date',None,None,None,None,'entered',None,'BL=M'),
 ('index_discharge_date','Enrolment','Discharge date of index HF admission','date',None,None,None,None,'entered',None,'BL=C'),
 # Clinical
 ('nyha_class','Clinical','NYHA functional class','coded',None,NYHA,None,None,'emr_derived','emr.clinical_assessment: clinical_assessments.nyha_class','*=M'),
 ('systolic_bp','Clinical','Systolic blood pressure','integer','mmHg',None,60,250,'emr_derived','emr.vitals_in_window: vital_signs.systolic_bp','*=M'),
 ('diastolic_bp','Clinical','Diastolic blood pressure','integer','mmHg',None,30,150,'emr_derived','emr.vitals_in_window: vital_signs.diastolic_bp','*=M'),
 ('heart_rate','Clinical','Heart rate','integer','bpm',None,30,200,'emr_derived','emr.vitals_in_window: vital_signs.heart_rate','*=M'),
 ('congestion_status','Clinical','Clinical congestion','coded',None,CONG,None,None,'emr_derived','emr.clinical_assessment: clinical_assessments.congestion_status','*=M'),
 ('jvp_raised','Clinical','JVP raised','boolean',None,None,None,None,'emr_derived','emr.clinical_assessment: clinical_assessments.jvp = raised','*=O'),
 ('peripheral_oedema','Clinical','Peripheral oedema present','boolean',None,None,None,None,'emr_derived','emr.clinical_assessment: peripheral_oedema <> none','*=O'),
 # Aetiology & phenotype
 ('primary_aetiology','Aetiology','Primary aetiology','coded',None,AET,None,None,'entered',None,'BL=M'),
 ('secondary_aetiologies','Aetiology','Contributing aetiologies','multi_coded',None,AET,None,None,'entered',None,'BL=O'),
 ('prior_lowest_lvef','Phenotype','Lowest documented LVEF before enrolment','numeric','%',None,5,90,'entered',None,'BL=C'),
 ('hf_phenotype','Phenotype','HF phenotype (clinician-confirmed)','coded',None,PHEN,None,None,'calculated','calc.hf_phenotype: registry.classify_hf_phenotype(lvef, prior_lowest_lvef)','BL=M M6=O M12=M ANNUAL=O'),
 # Echo
 ('echo_date','Echo','Date of echocardiogram used','date',None,None,None,None,'emr_derived','emr.echo_in_window: investigations.performed_on','BL=M M6=O M12=M ANNUAL=O'),
 ('lvef','Echo','LV ejection fraction','numeric','%',None,5,90,'emr_derived','emr.echo_in_window: echo_reports.lvef','BL=M M6=O M12=M ANNUAL=O'),
 ('lvef_method','Echo','LVEF method','coded',None,[(x,x.replace('_',' ')) for x in ['biplane_simpson','3d','teichholz','visual','other']],None,None,'emr_derived','emr.echo_in_window: echo_reports.lvef_method','BL=M M6=O M12=M ANNUAL=O'),
 ('lvedd_mm','Echo','LV end-diastolic diameter','numeric','mm',None,20,100,'emr_derived','emr.echo_in_window: echo_reports.lvedd_mm','BL=M M6=O M12=O ANNUAL=O'),
 ('lvesd_mm','Echo','LV end-systolic diameter','numeric','mm',None,10,90,'emr_derived','emr.echo_in_window: echo_reports.lvesd_mm','BL=O M6=O M12=O ANNUAL=O'),
 ('la_volume_index','Echo','LA volume index','numeric','mL/m2',None,5,300,'emr_derived','emr.echo_in_window: echo_reports.la_volume_index_ml_m2','BL=O M6=O M12=O ANNUAL=O'),
 ('tapse_mm','Echo','TAPSE','numeric','mm',None,2,40,'emr_derived','emr.echo_in_window: echo_reports.tapse_mm','BL=M M6=O M12=O ANNUAL=O'),
 ('rv_function','Echo','RV systolic function','coded',None,RVF,None,None,'emr_derived','emr.echo_in_window: echo_reports.rv_function','BL=M M6=O M12=O ANNUAL=O'),
 ('diastolic_grade','Echo','Diastolic dysfunction grade','coded',None,DIAST,None,None,'emr_derived','emr.echo_in_window: echo_reports.diastolic_grade','BL=O M12=O'),
 ('pasp_mmhg','Echo','Pulmonary artery systolic pressure','integer','mmHg',None,10,150,'emr_derived','emr.echo_in_window: echo_reports.pasp_mmhg','BL=O M12=O'),
 ('mr_severity','Echo','Mitral regurgitation severity','coded',None,[(x,x) for x in ['none','trivial','mild','moderate','moderate_severe','severe']],None,None,'emr_derived','emr.echo_valve: echo_valve_findings mitral regurgitation','BL=M M12=O'),
 # Laboratory
 ('nt_probnp','Laboratory','NT-proBNP','numeric','pg/mL',None,5,70000,'emr_derived','emr.lab_in_window: lab_results NT_PROBNP','BL=M M3=O M6=M M12=M ANNUAL=O'),
 ('haemoglobin','Laboratory','Haemoglobin','numeric','g/dL',None,3,22,'emr_derived','emr.lab_in_window: lab_results HB','BL=M M6=O M12=M ANNUAL=O'),
 ('creatinine','Laboratory','Serum creatinine','numeric','mg/dL',None,0.2,20,'emr_derived','emr.lab_in_window: lab_results CREATININE','BL=M M1=O M3=M M6=M M12=M ANNUAL=M'),
 ('egfr','Laboratory','eGFR (CKD-EPI 2021, race-free)','numeric','mL/min/1.73m2',None,2,200,'calculated','calc.egfr_ckd_epi_2021: creatinine, age, sex','BL=M M1=O M3=M M6=M M12=M ANNUAL=M'),
 ('sodium','Laboratory','Serum sodium','numeric','mmol/L',None,100,180,'emr_derived','emr.lab_in_window: lab_results NA','BL=M M1=O M3=M M6=O M12=M ANNUAL=O'),
 ('potassium','Laboratory','Serum potassium','numeric','mmol/L',None,1.5,9,'emr_derived','emr.lab_in_window: lab_results K','BL=M M1=O M3=M M6=O M12=M ANNUAL=O'),
 # Comorbidities
 ('has_diabetes','Comorbidities','Diabetes mellitus','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_DM','BL=M M12=O ANNUAL=O'),
 ('has_hypertension','Comorbidities','Hypertension','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_HTN','BL=M'),
 ('has_ckd','Comorbidities','Chronic kidney disease (eGFR < 60 or diagnosis)','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_CKD or eGFR < 60 twice 90 d apart','BL=M M12=O ANNUAL=O'),
 ('has_af','Comorbidities','Atrial fibrillation / flutter','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_AF','BL=M M12=O ANNUAL=O'),
 ('has_cad','Comorbidities','Coronary artery disease','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_CAD, DX_MI, DX_ICM','BL=M'),
 ('has_anaemia','Comorbidities','Anaemia (Hb < 13 g/dL men, < 12 g/dL women, or diagnosis)','boolean',None,None,None,None,'calculated','calc.anaemia_who: haemoglobin, sex','BL=M M12=O'),
]
PILLARS = [('rasi','ARNI / ACEI / ARB'), ('bb','Beta-blocker'), ('mra','MRA'), ('sglt2i','SGLT2 inhibitor')]
for code, name in PILLARS:
    HF += [
     (f'{code}_eligible','Medication (GDMT)',f'{name}: eligible for this phenotype','boolean',None,None,None,None,'calculated','calc.gdmt: ref.hf_pillar_eligibility','*=M'),
     (f'{code}_prescribed','Medication (GDMT)',f'{name}: prescribed','boolean',None,None,None,None,'calculated','calc.gdmt: registry.compute_gdmt','*=M'),
     (f'{code}_drug','Medication (GDMT)',f'{name}: drug','text',None,None,None,None,'calculated','calc.gdmt: ref.drugs.drug_code','*=C'),
     (f'{code}_daily_dose','Medication (GDMT)',f'{name}: total daily dose','numeric','mg/day',None,0,2000,'calculated','calc.gdmt: medication_events.daily_dose','*=C'),
     (f'{code}_pct_target','Medication (GDMT)',f'{name}: % of target daily dose','numeric','%',None,0,300,'calculated','calc.gdmt: daily dose / ref.hf_target_doses','*=C'),
     (f'{code}_dose_status','Medication (GDMT)',f'{name}: optimisation status','coded',None,GDMT_STATUS,None,None,'calculated','calc.gdmt + clinician confirmation','*=M'),
     (f'{code}_reasons','Medication (GDMT)',f'{name}: reasons not prescribed / not at target','multi_coded',None,GDMT_REASON,None,None,'entered',None,'*=C'),
    ]
HF += [
 ('gdmt_pillars_prescribed','Medication (GDMT)','Number of eligible pillars prescribed','integer','count',None,0,4,'calculated','calc.gdmt','*=M'),
 ('gdmt_pillars_at_target','Medication (GDMT)','Number of pillars at target dose','integer','count',None,0,4,'calculated','calc.gdmt','*=M'),
 ('loop_diuretic_furosemide_eq','Medication (other)','Loop diuretic, furosemide-equivalent daily dose (0 = none)','numeric','mg/day',None,0,1000,'calculated','calc.loop_diuretic_equivalent: furosemide 40 = torsemide 20 = bumetanide 1','*=M'),
 ('on_ivabradine','Medication (other)','Ivabradine','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: IVABRADINE','*=O'),
 ('on_digoxin','Medication (other)','Digoxin','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: DIGOXIN','*=O'),
 ('devices','Devices','Active cardiac devices','multi_coded',None,DEVICES,None,None,'emr_derived','emr.active_devices: cardiac_devices','BL=M M6=O M12=M ANNUAL=M'),
 # Outcomes (follow-up visits)
 ('vital_status','Outcomes','Vital status at visit','coded',None,VITAL,None,None,'entered',None,'M1=M M3=M M6=M M12=M ANNUAL=M'),
 ('hf_hospitalisations_since_last','Outcomes','HF hospitalisations since previous visit','integer','count',None,0,50,'calculated','calc.event_count: clinical_events hf_hospitalisation','M1=M M3=M M6=M M12=M ANNUAL=M'),
 ('urgent_hf_visits_since_last','Outcomes','Urgent HF visits since previous visit','integer','count',None,0,50,'calculated','calc.event_count: clinical_events urgent_hf_visit','M1=M M3=M M6=M M12=M ANNUAL=M'),
 ('worsening_hf_escalation','Outcomes','Worsening HF needing outpatient treatment escalation','boolean',None,None,None,None,'calculated','calc.event_exists: worsening_hf_outpatient','M1=M M3=M M6=M M12=M ANNUAL=M'),
 ('renal_deterioration','Outcomes','Renal deterioration (creatinine rise >= 0.3 mg/dL or eGFR fall >= 25%)','boolean',None,None,None,None,'calculated','calc.renal_deterioration vs baseline','M1=O M3=M M6=M M12=M ANNUAL=M'),
 ('hyperkalaemia','Outcomes','Hyperkalaemia (K > 5.5 mmol/L) since previous visit','boolean',None,None,None,None,'calculated','calc.lab_threshold: K > 5.5','M1=M M3=M M6=M M12=M ANNUAL=M'),
 ('symptomatic_hypotension','Outcomes','Symptomatic hypotension since previous visit','boolean',None,None,None,None,'calculated','calc.event_exists: hypotension','M1=M M3=M M6=M M12=M ANNUAL=M'),
]

LIPID_CATS = [(x, x.replace('_', ' ')) for x in ['primary_prevention','secondary_prevention','established_cad','post_mi',
              'post_pci','post_cabg','diabetes','familial_hypercholesterolaemia','elevated_lpa','statin_intolerance',
              'ckd','stroke_tia','pad']]
LAI_RISK = [(x, x.replace('_', ' ')) for x in ['extreme_a','extreme_b','very_high','high','moderate','low']]
RISK = [(x, x.replace('_', ' ')) for x in ['very_high','high','moderate','low','extreme']]
INTENS = [(x, x) for x in ['none','low','moderate','high']]
ADH = [(x, x) for x in ['good','partial','poor','unknown']]
TEST = [(x, x.replace('_', ' ')) for x in ['tested_in_window','tested_outside_window','not_tested']]
TSTAT = [(x, x.replace('_', ' ')) for x in ['at_target','not_at_target_on_max_tolerated','not_at_target_escalation_pending',
         'not_at_target_adherence_issue','no_repeat_test']]
CHANGE = [(x, x.replace('_', ' ')) for x in ['none','statin_initiated','statin_intensified','non_statin_added','reduced','stopped']]
NONINT = [(x, x.replace('_', ' ')) for x in ['at_target','intolerance','cost','patient_refusal','clinician_judgement',
          'awaiting_repeat_test','other']]
MUSCLE = [(x, x) for x in ['none','myalgia','myositis','rhabdomyolysis']]
SMOKE = [(x, x) for x in ['never','former','current','unknown']]
LDLM = [(x, x.replace('_', '-')) for x in ['direct','friedewald','martin_hopkins','sampson']]
BLK = [('untreated','Untreated (no lipid-lowering therapy)'),('on_treatment_at_enrolment','On treatment at enrolment'),
       ('imputed_untreated','Imputed untreated value')]

LIPID = [
 ('age_at_index','Demographics','Age at index date','integer','years',None,18,110,'calculated','calc.age_at_index','BL=M'),
 ('sex','Demographics','Sex','coded',None,SEX,None,None,'emr_derived','emr.registration_sex','BL=M'),
 ('bmi','Demographics','Body-mass index','numeric','kg/m2',None,10,70,'calculated','calc.bmi','BL=M M12=O ANNUAL=O'),
 ('prevention_type','Category','Primary or secondary prevention','coded',None,[('primary','Primary'),('secondary','Secondary')],None,None,'entered',None,'BL=M'),
 ('lipid_categories','Category','Patient categories (all that apply)','multi_coded',None,LIPID_CATS,None,None,'entered',None,'BL=M M12=O ANNUAL=O'),
 ('has_cad','Clinical','Coronary artery disease','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_CAD','BL=M'),
 ('prior_mi','Clinical','Previous myocardial infarction','boolean',None,None,None,None,'emr_derived','emr.event_before_index: mi','BL=M'),
 ('prior_stroke_tia','Clinical','Previous ischaemic stroke / TIA','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_STROKE','BL=M'),
 ('has_pad','Clinical','Peripheral arterial disease','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_PAD','BL=M'),
 ('has_diabetes','Clinical','Diabetes mellitus','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_DM','BL=M'),
 ('has_ckd','Clinical','Chronic kidney disease','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_CKD','BL=M'),
 ('has_hypertension','Clinical','Hypertension','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_HTN','BL=M'),
 ('smoking_status','Clinical','Smoking status','coded',None,SMOKE,None,None,'emr_derived','emr.lifestyle_latest','BL=M M12=O ANNUAL=O'),
 ('fh_basis','Clinical','FH diagnosis basis','coded',None,[('dlcn','Dutch Lipid Clinic Network'),('simon_broome','Simon Broome'),('genetic','Genetic'),('clinical','Clinical')],None,None,'entered',None,'BL=C'),
 ('dlcn_score','Clinical','DLCN score','integer','points',None,0,30,'entered',None,'BL=C'),
 ('ldl_guideline','Risk and target','Guideline rule set used for target','text',None,None,None,None,'calculated','calc.protocol_rule_set: registry_protocols.ldl_target_rule_set_id','*=M'),
 ('risk_category','Risk and target','ESC/EAS risk category','coded',None,RISK,None,None,'entered',None,'BL=M M12=O ANNUAL=O'),
 ('ldl_target','Risk and target','LDL-C target applied','numeric','mg/dL',None,10,200,'calculated','calc.ldl_target: ref.ldl_target_rules','*=M'),
 ('lai_risk_category','Risk and target','LAI risk category','coded',None,LAI_RISK,None,None,'entered',None,'BL=M M12=O ANNUAL=O'),
 ('ldl_target_lai','Risk and target','LDL-C target under LAI rule set','numeric','mg/dL',None,10,200,'calculated','calc.ldl_target: ref.ldl_target_rules (secondary rule set)','*=M'),
 ('ldl_target_met_lai','Outcomes','LDL-C target attained under LAI','boolean',None,None,None,None,'calculated','calc.ldl_target_met: secondary rule set','*=C'),
 ('baseline_ldl_kind','Lipids','Which value is the baseline LDL-C','coded',None,BLK,None,None,'entered',None,'BL=M'),
 ('lipid_test_status','Lipids','Lipid profile done in this visit window','coded',None,TEST,None,None,'calculated','calc.lab_in_window: LDL_C','*=M'),
 ('lipid_test_date','Lipids','Lipid sample date','date',None,None,None,None,'emr_derived','emr.lab_in_window: lab_results.collected_at','*=C'),
 ('ldl_c','Lipids','LDL cholesterol','numeric','mg/dL',None,5,1000,'emr_derived','emr.lab_in_window: LDL_C','*=C'),
 ('ldl_method','Lipids','LDL-C method','coded',None,LDLM,None,None,'emr_derived','emr.lab_in_window: lab_results.method','*=C'),
 ('total_cholesterol','Lipids','Total cholesterol','numeric','mg/dL',None,40,1500,'emr_derived','emr.lab_in_window: TC','*=C'),
 ('hdl_c','Lipids','HDL cholesterol','numeric','mg/dL',None,5,200,'emr_derived','emr.lab_in_window: HDL_C','*=C'),
 ('triglycerides','Lipids','Triglycerides','numeric','mg/dL',None,10,10000,'emr_derived','emr.lab_in_window: TG','*=C'),
 ('non_hdl_c','Lipids','Non-HDL cholesterol','numeric','mg/dL',None,10,1500,'calculated','calc.non_hdl: TC - HDL-C','*=C'),
 ('apob','Advanced lipids','Apolipoprotein B','numeric','mg/dL',None,10,400,'emr_derived','emr.lab_in_window: APOB','BL=O M12=O ANNUAL=O'),
 ('lpa_value','Advanced lipids','Lipoprotein(a), as reported','numeric',None,None,0,1000,'emr_derived','emr.lab_ever: LPA_NMOL_L or LPA_MG_DL','BL=O'),
 ('lpa_unit','Advanced lipids','Lp(a) unit','coded',None,[('nmol/L','nmol/L'),('mg/dL','mg/dL')],None,None,'emr_derived','emr.lab_ever: analyte used','BL=C'),
 ('lpa_elevated','Advanced lipids','Lp(a) elevated (>= 125 nmol/L or >= 50 mg/dL)','boolean',None,None,None,None,'calculated','calc.lpa_elevated','BL=C'),
 ('statin_drug','Treatment','Statin','text',None,None,None,None,'emr_derived','emr.active_drug_class: STATIN','*=M'),
 ('statin_daily_dose','Treatment','Statin daily dose','numeric','mg/day',None,0,80,'emr_derived','emr.active_drug_class: daily_dose','*=C'),
 ('statin_intensity','Treatment intensity','Statin intensity','coded',None,INTENS,None,None,'calculated','calc.statin_intensity: ref.statin_intensity_rules','*=M'),
 ('on_ezetimibe','Treatment','Ezetimibe','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: EZETIMIBE','*=M'),
 ('on_pcsk9_mab','Treatment','PCSK9 monoclonal antibody','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: PCSK9_MAB','*=M'),
 ('on_inclisiran','Treatment','Inclisiran','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: PCSK9_SIRNA','*=M'),
 ('on_bempedoic_acid','Treatment','Bempedoic acid','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: BEMPEDOIC_ACID','*=M'),
 ('therapy_change','Treatment','Change to lipid therapy at this visit','coded',None,CHANGE,None,None,'calculated','calc.llt_change vs previous visit','W6_12=M M6=M M12=M ANNUAL=M'),
 ('non_intensification_reason','Treatment','Reason therapy not intensified when not at target','coded',None,NONINT,None,None,'entered',None,'W6_12=C M6=C M12=C ANNUAL=C'),
 ('ck','Safety','Creatine kinase','numeric','U/L',None,5,100000,'emr_derived','emr.lab_in_window: CK','BL=O W6_12=O M6=O M12=O ANNUAL=O'),
 ('alt','Safety','ALT','numeric','U/L',None,1,5000,'emr_derived','emr.lab_in_window: ALT','BL=O W6_12=O M6=O M12=O ANNUAL=O'),
 ('muscle_symptoms','Safety','Statin-associated muscle symptoms','coded',None,MUSCLE,None,None,'entered',None,'W6_12=M M6=M M12=M ANNUAL=M'),
 ('adherence','Adherence','Adherence to lipid-lowering therapy','coded',None,ADH,None,None,'emr_derived','emr.adherence_latest','W6_12=M M6=M M12=M ANNUAL=M'),
 ('ldl_abs_reduction','Outcomes','Absolute LDL-C reduction from baseline','numeric','mg/dL',None,-500,1000,'calculated','calc.ldl_abs_reduction: baseline - current','W6_12=C M6=C M12=C ANNUAL=C'),
 ('ldl_pct_reduction','Outcomes','% LDL-C reduction from baseline','numeric','%',None,-500,100,'calculated','calc.ldl_pct_reduction: (baseline - current) / baseline x 100','W6_12=C M6=C M12=C ANNUAL=C'),
 ('reduction_50pct_met','Outcomes','>= 50% LDL-C reduction achieved','boolean',None,None,None,None,'calculated','calc.ldl_pct_reduction >= 50','W6_12=C M6=C M12=C ANNUAL=C'),
 ('ldl_target_met','Outcomes','LDL-C target attained','boolean',None,None,None,None,'calculated','calc.ldl_target_met: ref.ldl_target_rules','*=C'),
 ('target_status','Outcomes','Target status (separates no repeat test from not at target)','coded',None,TSTAT,None,None,'calculated','calc.lipid_target_status','W6_12=M M6=M M12=M ANNUAL=M'),
 ('cv_events_since_last','Outcomes','Cardiovascular events since previous visit','integer','count',None,0,50,'calculated','calc.event_count: mi, stroke, pci, cabg, death (cv)','W6_12=M M6=M M12=M ANNUAL=M'),
]

# ---------------------------------------------------------------- CAD (migration 0003)
CAD_VISITS = ['BL', 'M1', 'M6', 'M12', 'ANNUAL']
FU = 'M1=M M6=M M12=M ANNUAL=M'
PRESENT = [(x, x.replace('_', ' ')) for x in ['chronic_coronary_syndrome', 'STEMI', 'NSTEMI', 'unstable_angina',
           'prior_mi_stable', 'prior_revascularisation_stable', 'other']]
CADCAT = [(x, x.replace('_', ' ')) for x in ['chronic_coronary_syndrome', 'acute_coronary_syndrome', 'STEMI', 'NSTEMI',
          'unstable_angina', 'previous_mi', 'previous_pci', 'previous_cabg', 'multivessel', 'left_main', 'cto', 'bifurcation']]
CCS = [('0', 'No angina'), ('I', 'CCS I'), ('II', 'CCS II'), ('III', 'CCS III'), ('IV', 'CCS IV')]
KILLIP = [(x, 'Killip ' + x) for x in ['I', 'II', 'III', 'IV']]
SYMPT = [(x, x.replace('_', ' ')) for x in ['none', 'typical_angina', 'atypical_angina', 'non_anginal_pain',
         'dyspnoea_equivalent', 'silent_ischaemia']]
REPERF = [(x, x.replace('_', ' ')) for x in ['primary_pci', 'pharmacoinvasive', 'thrombolysis_only', 'rescue_pci',
          'none_late_presentation', 'none_other']]
TROP = [('HS_TNI', 'hs-troponin I'), ('HS_TNT', 'hs-troponin T')]
DOM = [(x, x) for x in ['right', 'left', 'codominant']]
EXTENT = [('normal', 'Normal'), ('non_obstructive', 'Non-obstructive'), ('SVD', 'Single-vessel'),
          ('DVD', 'Double-vessel'), ('TVD', 'Triple-vessel')]
VESSELS = [(x, x) for x in ['LM', 'LAD', 'LCX', 'RCA']]
STRAT = [(x, x.replace('_', ' ')) for x in ['medical', 'pci', 'cabg', 'pci_planned', 'cabg_planned', 'hybrid']]
PCI_IND = [(x, x.replace('_', ' ')) for x in ['primary_pci_stemi', 'pharmacoinvasive', 'rescue_pci', 'nstemi',
           'unstable_angina', 'chronic_coronary_syndrome', 'staged', 'silent_ischaemia', 'other']]
URG = [(x, x) for x in ['elective', 'urgent', 'emergency', 'salvage']]
ACCESS = [(x, x.replace('_', ' ')) for x in ['radial', 'distal_radial', 'femoral', 'brachial', 'ulnar']]
TREATED = [(x, x) for x in ['LM', 'LAD', 'LCX', 'RCA', 'RAMUS', 'DIAGONAL', 'OM', 'PDA', 'PLV', 'SVG', 'LIMA', 'RIMA',
           'RADIAL_GRAFT']]
DEVTYPE = [(x, x) for x in ['DES', 'BMS', 'BVS', 'DCB', 'covered']]
IMG = [(x, x.replace('_', ' ')) for x in ['none', 'IVUS', 'OCT', 'IVUS_and_OCT']]
PHYS = [(x, x) for x in ['none', 'FFR', 'iFR', 'RFR', 'QFR', 'other']]
COMPL = [(x, x.replace('_', ' ')) for x in ['none', 'dissection', 'perforation', 'no_reflow', 'side_branch_occlusion',
         'acute_stent_thrombosis', 'access_bleeding', 'haematoma', 'pseudoaneurysm', 'contrast_nephropathy',
         'arrhythmia', 'stroke', 'death', 'other']]
P2Y12 = [(x, x) for x in ['none', 'clopidogrel', 'ticagrelor', 'prasugrel']]
DAPT_ST = [(x, x.replace('_', ' ')) for x in ['on_dapt', 'completed_as_planned', 'interrupted', 'stopped_bleeding',
           'stopped_other', 'never_started']]
CAD = [
 # Demographics
 ('age_at_index','Demographics','Age at index date','integer','years',None,18,110,'calculated','calc.age_at_index: registration DOB to enrolment index date','BL=M'),
 ('sex','Demographics','Sex','coded',None,SEX,None,None,'emr_derived','emr.registration_sex: patient_registrations.sex','BL=M'),
 ('weight_kg','Demographics','Weight','numeric','kg',None,25,250,'emr_derived','emr.vitals_in_window: vital_signs.weight_kg in visit window','BL=M M12=O ANNUAL=O'),
 ('bmi','Demographics','Body-mass index','numeric','kg/m2',None,10,70,'calculated','calc.bmi: weight / height^2','BL=M M12=O ANNUAL=O'),
 # Presentation
 ('presentation','Presentation','Presentation at index event','coded',None,PRESENT,None,None,'entered',None,'BL=M'),
 ('cad_categories','Presentation','CAD categories (all that apply)','multi_coded',None,CADCAT,None,None,'entered',None,'BL=M M12=O ANNUAL=O'),
 ('index_event_date','Presentation','Index event date','date',None,None,None,None,'entered',None,'BL=M'),
 ('symptom_type','Presentation','Presenting symptom','coded',None,SYMPT,None,None,'entered',None,'BL=M'),
 ('symptom_to_door_hours','Presentation','Symptom onset to first medical contact (ACS)','numeric','hours',None,0,720,'entered',None,'BL=C'),
 ('reperfusion_strategy','Presentation','Reperfusion strategy (STEMI)','coded',None,REPERF,None,None,'entered',None,'BL=C'),
 ('killip_class','Presentation','Killip class at presentation (ACS)','coded',None,KILLIP,None,None,'entered',None,'BL=C'),
 ('ccs_class','Clinical','Angina class (CCS)','coded',None,CCS,None,None,'emr_derived','emr.clinical_assessment: clinical_assessments.ccs_class','*=M'),
 # Risk factors and history
 ('has_diabetes','Risk factors','Diabetes mellitus','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_DM','BL=M M12=O ANNUAL=O'),
 ('has_hypertension','Risk factors','Hypertension','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_HTN','BL=M'),
 ('has_dyslipidaemia','Risk factors','Dyslipidaemia','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_DYSLIPIDAEMIA, DX_FH or on lipid-lowering therapy','BL=M'),
 ('smoking_status','Risk factors','Smoking status','coded',None,SMOKE,None,None,'emr_derived','emr.lifestyle_latest','*=M'),
 ('family_history_premature_cad','Risk factors','Premature CAD in a first-degree relative','boolean',None,None,None,None,'emr_derived','emr.family_history: is_premature, CAD concepts','BL=M'),
 ('has_ckd','Risk factors','Chronic kidney disease (eGFR < 60 or diagnosis)','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_CKD or eGFR < 60 twice 90 d apart','BL=M'),
 ('prior_mi','History','Previous myocardial infarction (before index event)','boolean',None,None,None,None,'emr_derived','emr.event_before_index: mi','BL=M'),
 ('prior_pci','History','Previous PCI (before index event)','boolean',None,None,None,None,'emr_derived','emr.event_before_index: pci','BL=M'),
 ('prior_cabg','History','Previous CABG','boolean',None,None,None,None,'emr_derived','emr.event_before_index: cabg','BL=M'),
 ('prior_stroke_tia','History','Previous ischaemic stroke / TIA','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_STROKE','BL=M'),
 ('has_pad','History','Peripheral arterial disease','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_PAD','BL=M'),
 ('has_af','History','Atrial fibrillation / flutter','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_AF','BL=M M12=O ANNUAL=O'),
 ('has_heart_failure','History','Heart failure','boolean',None,None,None,None,'emr_derived','emr.active_diagnosis: DX_HF','BL=M'),
 # Clinical
 ('systolic_bp','Clinical','Systolic blood pressure','integer','mmHg',None,60,250,'emr_derived','emr.vitals_in_window: vital_signs.systolic_bp','*=M'),
 ('diastolic_bp','Clinical','Diastolic blood pressure','integer','mmHg',None,30,150,'emr_derived','emr.vitals_in_window: vital_signs.diastolic_bp','*=M'),
 ('heart_rate','Clinical','Heart rate','integer','bpm',None,30,200,'emr_derived','emr.vitals_in_window: vital_signs.heart_rate','*=M'),
 # Laboratory
 ('peak_troponin','Laboratory','Peak high-sensitivity troponin (index admission)','numeric','ng/L',None,0,500000,'emr_derived','emr.lab_peak_in_admission: lab_results HS_TNI or HS_TNT','BL=C'),
 ('troponin_assay','Laboratory','Troponin assay','coded',None,TROP,None,None,'emr_derived','emr.lab_peak_in_admission: analyte of peak_troponin','BL=C'),
 ('creatinine','Laboratory','Serum creatinine','numeric','mg/dL',None,0.2,20,'emr_derived','emr.lab_in_window: lab_results CREATININE','BL=M M12=M ANNUAL=O'),
 ('egfr','Laboratory','eGFR (CKD-EPI 2021, race-free)','numeric','mL/min/1.73m2',None,2,200,'calculated','calc.egfr_ckd_epi_2021: creatinine, age, sex','BL=M M12=M ANNUAL=O'),
 ('haemoglobin','Laboratory','Haemoglobin','numeric','g/dL',None,3,22,'emr_derived','emr.lab_in_window: lab_results HB','BL=M M1=O M12=O ANNUAL=O'),
 ('ldl_c','Laboratory','LDL cholesterol','numeric','mg/dL',None,5,1000,'emr_derived','emr.lab_in_window: lab_results LDL_C','BL=M M1=O M6=M M12=M ANNUAL=M'),
 ('hdl_c','Laboratory','HDL cholesterol','numeric','mg/dL',None,5,200,'emr_derived','emr.lab_in_window: lab_results HDL_C','BL=M M6=O M12=O ANNUAL=O'),
 ('triglycerides','Laboratory','Triglycerides','numeric','mg/dL',None,10,10000,'emr_derived','emr.lab_in_window: lab_results TG','BL=M M6=O M12=O ANNUAL=O'),
 ('hba1c','Laboratory','HbA1c','numeric','%',None,3,20,'emr_derived','emr.lab_in_window: lab_results HBA1C','BL=M M12=C ANNUAL=C'),
 ('lpa','Laboratory','Lipoprotein(a), as reported','numeric',None,None,0,1000,'emr_derived','emr.lab_ever: lab_results LPA_NMOL_L or LPA_MG_DL, unit kept','BL=O'),
 # Echo
 ('lvef','Echo','LV ejection fraction','numeric','%',None,5,90,'emr_derived','emr.echo_in_window: echo_reports.lvef','BL=M M12=O ANNUAL=O'),
 ('rwma','Echo','Regional wall-motion abnormality','boolean',None,None,None,None,'emr_derived','emr.echo_in_window: echo_reports regional wall motion','BL=M M12=O'),
 # Coronary anatomy (index angiogram)
 ('angiography_done','Coronary anatomy','Coronary angiography for the index event','boolean',None,None,None,None,'emr_derived','emr.index_angiogram: coronary_angiograms within 30 d of index','BL=M'),
 ('angiography_date','Coronary anatomy','Date of index angiogram','date',None,None,None,None,'emr_derived','emr.index_angiogram: investigations.performed_on','BL=C'),
 ('dominance','Coronary anatomy','Coronary dominance','coded',None,DOM,None,None,'emr_derived','emr.index_angiogram: coronary_angiograms.dominance','BL=C'),
 ('disease_extent','Coronary anatomy','Disease extent','coded',None,EXTENT,None,None,'emr_derived','emr.index_angiogram: coronary_angiograms.disease_extent','BL=C'),
 ('diseased_vessels','Coronary anatomy','Vessels with significant stenosis (LM >= 50%, others >= 70%)','multi_coded',None,VESSELS,None,None,'calculated','calc.diseased_vessels: coronary_segment_findings','BL=C'),
 ('left_main_disease','Coronary anatomy','Left main stenosis >= 50%','boolean',None,None,None,None,'emr_derived','emr.index_angiogram: coronary_angiograms.left_main_disease','BL=C'),
 ('proximal_lad_disease','Coronary anatomy','Proximal LAD stenosis >= 70%','boolean',None,None,None,None,'calculated','calc.segment_stenosis: LAD segment 6 >= 70%','BL=C'),
 ('cto_present','Coronary anatomy','Chronic total occlusion present','boolean',None,None,None,None,'calculated','calc.segment_flag: coronary_segment_findings.is_cto','BL=C'),
 ('bifurcation_disease','Coronary anatomy','Bifurcation lesion present','boolean',None,None,None,None,'calculated','calc.segment_flag: coronary_segment_findings.is_bifurcation','BL=C'),
 ('syntax_score','Coronary anatomy','SYNTAX score','numeric','points',None,0,100,'emr_derived','emr.index_angiogram: coronary_angiograms.syntax_score','BL=O'),
 # Revascularisation strategy
 ('initial_strategy','Treatment strategy','Initial treatment strategy','coded',None,STRAT,None,None,'entered',None,'BL=M'),
 ('index_pci_done','Treatment strategy','PCI for the index event','boolean',None,None,None,None,'calculated','calc.index_pci: pci_procedures within 30 d of index, status final','BL=M'),
 ('index_cabg_done','Treatment strategy','CABG for the index event','boolean',None,None,None,None,'calculated','calc.event_in_window: cabg within 90 d of index','BL=M M1=O'),
 ('cabg_date','Treatment strategy','CABG date','date',None,None,None,None,'emr_derived','emr.event_in_window: clinical_events cabg','BL=C M1=C'),
 # Index PCI summary (all calculated from the PCI record; filled when index_pci_done)
 ('pci_date','Index PCI','Index PCI date','date',None,None,None,None,'emr_derived','emr.index_pci: pci_procedures.procedure_date','BL=C'),
 ('pci_indication','Index PCI','Clinical indication','coded',None,PCI_IND,None,None,'emr_derived','emr.index_pci: pci_procedures.indication','BL=C'),
 ('pci_urgency','Index PCI','Urgency','coded',None,URG,None,None,'emr_derived','emr.index_pci: pci_procedures.urgency','BL=C'),
 ('pci_access_site','Index PCI','Access site','coded',None,ACCESS,None,None,'emr_derived','emr.index_pci: pci_procedures.access_site','BL=C'),
 ('pci_vessels_treated','Index PCI','Vessels treated','multi_coded',None,TREATED,None,None,'calculated','calc.pci_summary: pci_lesions.vessel','BL=C'),
 ('pci_lesions_treated','Index PCI','Number of lesions treated','integer','count',None,1,20,'calculated','calc.pci_summary: count pci_lesions','BL=C'),
 ('pci_stents_count','Index PCI','Number of stents','integer','count',None,0,20,'calculated','calc.pci_summary: count pci_stents','BL=C'),
 ('pci_total_stent_length_mm','Index PCI','Total stent length','numeric','mm',None,0,400,'calculated','calc.pci_summary: sum pci_stents.length_mm','BL=C'),
 ('pci_min_stent_diameter_mm','Index PCI','Smallest stent diameter','numeric','mm',None,1.5,6,'calculated','calc.pci_summary: min pci_stents.diameter_mm','BL=C'),
 ('pci_device_types','Index PCI','Device types used','multi_coded',None,DEVTYPE,None,None,'calculated','calc.pci_summary: ref.stent_devices.device_type','BL=C'),
 ('pci_bifurcation_treated','Index PCI','Bifurcation lesion treated','boolean',None,None,None,None,'calculated','calc.pci_summary: any pci_lesions.is_bifurcation','BL=C'),
 ('pci_cto_treated','Index PCI','CTO treated','boolean',None,None,None,None,'calculated','calc.pci_summary: any pci_lesions.is_cto','BL=C'),
 ('pci_imaging','Index PCI','Intravascular imaging','coded',None,IMG,None,None,'emr_derived','emr.index_pci: pci_procedures.imaging_guidance','BL=C'),
 ('pci_physiology','Index PCI','Physiology assessment','coded',None,PHYS,None,None,'emr_derived','emr.index_pci: pci_procedures.physiology','BL=C'),
 ('pci_final_timi3','Index PCI','Final TIMI 3 flow in every treated lesion','boolean',None,None,None,None,'calculated','calc.pci_summary: all pci_lesions.final_timi_flow = 3','BL=C'),
 ('pci_success','Index PCI','Procedural success','boolean',None,None,None,None,'emr_derived','emr.index_pci: pci_procedures.procedural_success','BL=C'),
 ('pci_complications','Index PCI','Procedural complications','multi_coded',None,COMPL,None,None,'emr_derived','emr.index_pci: pci_procedures.complications','BL=C'),
 ('staged_pci_planned','Index PCI','Staged PCI planned','boolean',None,None,None,None,'entered',None,'BL=O'),
 # Secondary prevention
 ('on_aspirin','Medication','Aspirin','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: ANTIPLATELET (aspirin) on visit date','*=M'),
 ('p2y12_agent','Medication','P2Y12 inhibitor','coded',None,P2Y12,None,None,'emr_derived','emr.active_drug_class: P2Y12I on visit date','*=M'),
 ('on_dapt','Medication','Dual antiplatelet therapy','boolean',None,None,None,None,'calculated','calc.dapt: aspirin and P2Y12 inhibitor both active','*=M'),
 ('dapt_planned_months','Medication','Planned DAPT duration','integer','months',None,0,36,'entered',None,'BL=C'),
 ('on_oac','Medication','Oral anticoagulant','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: ANTICOAGULANT on visit date','*=M'),
 ('statin_intensity','Medication','Statin intensity','coded',None,INTENS,None,None,'calculated','calc.statin_intensity: ref.statin_intensity_rules','*=M'),
 ('on_ezetimibe','Medication','Ezetimibe','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: EZETIMIBE','*=M'),
 ('on_pcsk9_therapy','Medication','PCSK9 antibody or inclisiran','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: PCSK9_MAB, PCSK9_SIRNA','*=O'),
 ('on_beta_blocker','Medication','Beta-blocker','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: BETA_BLOCKER','*=M'),
 ('on_acei_arb_arni','Medication','ACE inhibitor, ARB or ARNI','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: ACEI, ARB, ARNI','*=M'),
 ('on_sglt2i','Medication','SGLT2 inhibitor','boolean',None,None,None,None,'emr_derived','emr.active_drug_class: SGLT2I','*=O'),
 # Outcomes since previous visit (counts come from events; endpoint status from adjudication)
 ('vital_status','Outcomes','Vital status at visit','coded',None,VITAL,None,None,'entered',None,FU),
 ('cv_death','Outcomes','Cardiovascular death','boolean',None,None,None,None,'calculated','calc.event_exists: death with death_cause = cardiovascular',FU),
 ('mi_since_last','Outcomes','Myocardial infarction since previous visit','boolean',None,None,None,None,'calculated','calc.event_exists: mi',FU),
 ('stroke_since_last','Outcomes','Stroke since previous visit','boolean',None,None,None,None,'calculated','calc.event_exists: stroke',FU),
 ('tlr_since_last','Outcomes','Target lesion revascularisation since previous visit','boolean',None,None,None,None,'calculated','calc.event_exists: pci or cabg on an index target lesion',FU),
 ('tvr_since_last','Outcomes','Target vessel revascularisation since previous visit','boolean',None,None,None,None,'calculated','calc.event_exists: pci or cabg in an index treated vessel',FU),
 ('any_revasc_since_last','Outcomes','Any repeat revascularisation since previous visit','boolean',None,None,None,None,'calculated','calc.event_exists: pci, cabg (excluding planned staged PCI)',FU),
 ('stent_thrombosis_since_last','Outcomes','Stent thrombosis since previous visit','boolean',None,None,None,None,'calculated','calc.event_exists: stent_thrombosis',FU),
 ('major_bleeding_since_last','Outcomes','Bleeding BARC 3 to 5 since previous visit','boolean',None,None,None,None,'calculated','calc.event_exists: bleeding, BARC 3-5 by adjudication or reported severity',FU),
 ('hf_hospitalisation_since_last','Outcomes','Heart failure hospitalisation since previous visit','boolean',None,None,None,None,'calculated','calc.event_exists: hf_hospitalisation',FU),
 ('dapt_status','Outcomes','DAPT status at visit','coded',None,DAPT_ST,None,None,'entered',None,'M1=M M6=M M12=M ANNUAL=O'),
]

def q(x):
    if x is None: return 'NULL'
    if isinstance(x, (int, float)): return str(x)
    return "'" + str(x).replace("'", "''") + "'"

def seed(reg, rows, visits, protocol_code, FILTER_0001=False):
    out = []
    for (code, cat, label, typ, unit, allowed, mn, mx, sk, src, vis) in rows:
        av = json.dumps([{'code': c, 'label': l} for c, l in allowed]) if allowed else None
        deriv = src.split(':')[0] if src else None
        emr = src.split(':', 1)[1].strip() if src and ':' in src else src
        if FILTER_0001 and code in {'lai_risk_category','ldl_target_lai','ldl_target_met_lai'}: continue
        out.append(f"INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, "
                   f"data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) "
                   f"SELECT registry_type_id, {q(code)}, {q(cat)}, {q(label)}, {q(typ)}, {q(unit)}, {q(av)}::jsonb, "
                   f"{q(mn)}, {q(mx)}, {q(sk)}, {q(deriv)}, {q(emr)}, 'active' FROM registry.registry_types WHERE registry_code = '{reg}';")
        req = v(vis, visits)
        for i, (vc, r) in enumerate(req.items()):
            rr = {'M': 'mandatory', 'C': 'conditional', 'O': 'optional'}[r]
            out.append(f"INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) "
                       f"SELECT p.protocol_id, d.variable_id, '{vc}', '{rr}', {rows.index(next(x for x in rows if x[0]==code))} "
                       f"FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) "
                       f"WHERE p.protocol_code = '{protocol_code}' AND p.protocol_version = 1 AND t.registry_code = '{reg}' "
                       f"AND d.variable_code = '{code}' AND d.definition_version = 1;")
    return out

def to_csv(path, rows, visits):
    with open(path, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['variable_code', 'category', 'label', 'data_type', 'unit', 'allowed_values', 'min', 'max',
                    'source_kind', 'emr_source_or_rule'] + visits)
        for (code, cat, label, typ, unit, allowed, mn, mx, sk, src, vis) in rows:
            req = v(vis, visits)
            w.writerow([code, cat, label, typ, unit or '', '; '.join(c for c, _ in allowed) if allowed else '',
                        '' if mn is None else mn, '' if mx is None else mx, sk, src or ''] + [req.get(x, '') for x in visits])

def to_md(rows, visits, compact_pillars=False):
    lines = ['| Category | Variable | Type and unit | Source | ' + ' | '.join(visits) + ' |',
             '| --- | --- | --- | --- | ' + ' | '.join('---' for _ in visits) + ' |']
    seen_pillar = False
    for (code, cat, label, typ, unit, allowed, mn, mx, sk, src, vis) in rows:
        if compact_pillars and any(code.startswith(p + '_') for p, _ in PILLARS) and not code.startswith('gdmt'):
            if seen_pillar: continue
            seen_pillar = True
            lines.append('| Medication (GDMT) | Per pillar (RASi, beta-blocker, MRA, SGLT2i): `eligible`, `prescribed`, `drug`, '
                         '`daily_dose` (mg/day), `pct_target` (%), `dose_status`, `reasons` | 7 fields x 4 pillars | calculated, '
                         'reasons entered | ' + ' | '.join('M' for _ in visits) + ' |')
            continue
        req = v(vis, visits)
        tu = typ + (f', {unit}' if unit else '')
        if mn is not None: tu += f' ({mn} to {mx})'
        srcs = {'emr_derived': 'EMR', 'calculated': 'calculated', 'entered': 'entered'}[sk]
        lines.append(f'| {cat} | `{code}`: {label} | {tu} | {srcs} | ' + ' | '.join(req.get(x, '') for x in visits) + ' |')
    return '\n'.join(lines)

os.makedirs(OUT, exist_ok=True)
NEW_IN_0002 = {'lai_risk_category','ldl_target_lai','ldl_target_met_lai'}
with open(os.path.join(OUT, 'dictionary_seed_0002.sql'), 'w') as f:
    f.write('-- Generated by dictionaries.py: lipid dictionary additions for migration 0002\n')
    f.write('\n'.join(seed('LIPID', [r for r in LIPID if r[0] in NEW_IN_0002], LP_VISITS, 'CEMR-LIPID')) + '\n')
with open(os.path.join(OUT, 'dictionary_seed.sql'), 'w') as f:
    f.write('-- Generated by dictionaries.py: HF and lipid data dictionaries v1\n')
    f.write('\n'.join(seed('HF', HF, HF_VISITS, 'CEMR-HF')) + '\n')
    f.write('\n'.join(seed('LIPID', LIPID, LP_VISITS, 'CEMR-LIPID', True)) + '\n')
to_csv(os.path.join(OUT, 'hf_data_dictionary_v1.csv'), HF, HF_VISITS)
to_csv(os.path.join(OUT, 'lipid_data_dictionary_v1.csv'), LIPID, LP_VISITS)
open(os.path.join(OUT, 'hf_dictionary.md'), 'w').write(to_md(HF, HF_VISITS, True))
open(os.path.join(OUT, 'lipid_dictionary.md'), 'w').write(to_md(LIPID, LP_VISITS))
with open(os.path.join(OUT, 'dictionary_seed_0003.sql'), 'w') as f:
    f.write('-- Generated by dictionaries.py: CAD data dictionary v1 for migration 0003\n')
    f.write('\n'.join(seed('CAD', CAD, CAD_VISITS, 'CEMR-CAD')) + '\n')
to_csv(os.path.join(OUT, 'cad_data_dictionary_v1.csv'), CAD, CAD_VISITS)
open(os.path.join(OUT, 'cad_dictionary.md'), 'w').write(to_md(CAD, CAD_VISITS))
print(len(HF), len(LIPID), len(CAD))
