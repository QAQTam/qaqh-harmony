import clientUnit from './ClientContract.test';
import streamUnit from './StreamContract.test';
import interactionUnit from './InteractionContract.test';
import deviceAccessUnit from './DeviceAccessContract.test';
import timelineUnit from './TimelineContract.test';
import configRpcUnit from './ConfigRpcContract.test';

export default function testsuite() {
  clientUnit();
  streamUnit();
  interactionUnit();
  deviceAccessUnit();
  timelineUnit();
  configRpcUnit();
}
