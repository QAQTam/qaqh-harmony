import localUnit from './ProtocolContract.test';
import timelineUnit from './TimelineContract.test';
import configUnit from './ConfigContract.test';
import approvalsUnit from './ApprovalsContract.test';

export default function testsuite() {
  localUnit();
  timelineUnit();
  configUnit();
  approvalsUnit();
}
