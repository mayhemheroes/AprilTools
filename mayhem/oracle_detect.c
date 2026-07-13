/* Behavioral known-answer oracle for AprilTools (AUTHORED — upstream ships no
 * test suite). AprilTools runs the AprilTag detector over frames and reports the
 * detected tags; this oracle drives that exact code path (apriltag_detector_detect)
 * on real grayscale frames shipped in the repo (testAnim frames, pre-converted to
 * PGM under mayhem/oracle-data/) and asserts the known ground truth: each frame
 * contains exactly one tag36h11 marker with id 0 and hamming 0. A patch that
 * neuters detection (returns no tags / exits early) makes these assertions FAIL. */
#include <stdio.h>
#include <string.h>

#include "apriltag.h"
#include "tag36h11.h"
#include "common/image_u8.h"
#include "common/zarray.h"

static int passed = 0, failed = 0;
static void ok(const char *n)  { printf("ok - %s\n", n);   passed++; }
static void bad(const char *n) { printf("FAIL - %s\n", n); failed++; }

int main(int argc, char **argv) {
    const char *dir = (argc > 1) ? argv[1] : ".";
    struct { const char *file; int id; } cases[] = {
        { "0001.pgm", 0 },
        { "0040.pgm", 0 },
    };

    apriltag_family_t *tf = tag36h11_create();
    apriltag_detector_t *td = apriltag_detector_create();
    apriltag_detector_add_family_bits(td, tf, 1);
    td->quad_decimate = 2.0f;
    td->quad_sigma = 0.0f;
    td->nthreads = 1;
    td->refine_edges = 1;

    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        char path[512], name[256];
        snprintf(path, sizeof path, "%s/%s", dir, cases[i].file);
        image_u8_t *im = image_u8_create_from_pnm(path);
        if (!im) {
            snprintf(name, sizeof name, "load %s", cases[i].file);
            bad(name);
            continue;
        }
        zarray_t *dets = apriltag_detector_detect(td, im);
        int n = zarray_size(dets);
        int got_id = -1, ham = -1;
        if (n > 0) {
            apriltag_detection_t *d;
            zarray_get(dets, 0, &d);
            got_id = d->id; ham = d->hamming;
        }
        snprintf(name, sizeof name,
                 "%s detects exactly one tag36h11 id=%d (got n=%d id=%d ham=%d)",
                 cases[i].file, cases[i].id, n, got_id, ham);
        if (n == 1 && got_id == cases[i].id && ham == 0) ok(name); else bad(name);
        apriltag_detections_destroy(dets);
        image_u8_destroy(im);
    }

    apriltag_detector_destroy(td);
    tag36h11_destroy(tf);
    printf("passed=%d failed=%d\n", passed, failed);
    return failed ? 1 : 0;
}
